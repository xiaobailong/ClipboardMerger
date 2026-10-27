# 剪集 (ClipboardMerger) – Architecture Guide

## Overview

Android 剪贴板合并工具「剪集」，支持输入法（IME）内嵌剪贴板面板，实时监听系统剪贴板变化并自动合并/管理剪贴历史。

---

## Entry Points

**Main Activity** (`android/app/src/main/java/com/example/clipboardmerger/MainActivity.kt`):
主界面，剪贴板管理入口。提供剪贴历史的查看、搜索、删除、合并等功能。

**IME Service** (`ClipboardInputMethodService.kt`):
输入法服务，内嵌剪贴板面板。在用户使用输入法时直接展示剪贴板历史，支持一键粘贴。

**Background Service** (`ClipboardService.kt`):
后台剪贴板监听服务。实时监听系统剪贴板变化，自动记录新的剪贴内容。

---

## Architecture

```
ClipboardMerger/
├── android/app/src/main/java/com/example/clipboardmerger/
│   ├── MainActivity.kt                  # 主界面，剪贴板管理
│   ├── ClipboardInputMethodService.kt   # IME 输入法服务，内嵌剪贴板面板
│   ├── ClipboardService.kt              # 后台剪贴板监听服务
│   ├── ClipboardViewModel.kt            # ViewModel，数据绑定
│   ├── ClipboardRepository.kt           # 数据仓库层
│   ├── ClipboardItem.kt                 # 剪贴项数据模型
│   ├── ClipboardAdapter.kt              # 主界面 RecyclerView 适配器
│   ├── ImeClipboardAdapter.kt           # IME 面板 RecyclerView 适配器
│   ├── GitHubHelper.kt                  # GitHub Release 检查更新
│   └── Logger.kt                        # 日志工具类（文件日志 + 自动清理）
├── harmony/                             # 鸿蒙版代码
├── scripts/
│   ├── build.bat                        # Android 一键构建脚本
│   ├── build-harmony.bat                # 鸿蒙一键构建脚本
│   ├── clean.bat                        # 清理构建产物
│   ├── gh-release.bat                   # 单独补发 GitHub Release
│   ├── deploy-harmony.bat               # 鸿蒙版装机脚本
│   └── tools/
│       ├── tee-log.ps1                  # 日志 tee 包装器
│       ├── build-info.js                # 鸿蒙构建信息
│       └── harmony-version.js           # 鸿蒙版本号工具
└── memory-bank/                         # 知识库
```

---

## Data Flow

```
1. System Clipboard Change → ClipboardService.onPrimaryClipChanged()
2. ClipboardService → ClipboardRepository.addItem(item)
3. ClipboardRepository → Room DB (if persistence enabled)
4. ClipboardViewModel observes Repository → LiveData updates
5. MainActivity/IME adapters update via data binding
```

`selfUpdating` 标记避免循环更新：应用自身修改剪贴板时设置标记，避免被自己的监听再次捕获。

---

## Settings

- 通过 SharedPreferences `clipboard_merger_settings` 管理
- `log_enabled` 键控制日志开关
- Logger 工具类支持文件日志（`/JianJi/` 目录），自动清理 7 天前日志

---

## Build

- **构建**: Gradle 8.5 / AGP 8.2.0 / JDK 17
- **版本号**: `android/version.properties` 是唯一真源
- **最低 SDK**: 26, **目标 SDK**: 34
- **完整构建**: `scripts\build.bat`（含 git 提交/推送/打 tag/`gh release create`）
- **自测编译**: 直接跑 Gradle 命令，不跑 `build.bat`

```cmd
set JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-17.0.10-oracle
set ANDROID_HOME=D:\Tools\DevTools\Android\Sdk
set ANDROID_SDK_ROOT=D:\Tools\DevTools\Android\Sdk
set "PATH=D:\Tools\DevTools\Java\JDK\jdk-17.0.10-oracle\bin;D:\Tools\DevTools\gradle\gradle-8.5\bin;%PATH%"
cd /d "d:\WorkSpace\test\ClipboardMerger\android"
call gradle assembleDebug & exit
```

---

## Key Dependencies

| Dependency | Purpose |
|-----------|---------|
| ViewModel + LiveData | MVVM architecture |
| Coroutines | Async operations |
| ViewBinding | View access |
| Material Design | UI components |
| RecyclerView | List display |
| SwipeRefreshLayout | Pull-to-refresh |