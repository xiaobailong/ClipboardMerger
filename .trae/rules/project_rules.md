# 剪集 项目规则

## 概述
Android 剪贴板合并工具「剪集」，支持输入法（IME）内嵌剪贴板面板，实时监听系统剪贴板变化并自动合并/管理剪贴历史。

## 技术栈
- **语言**: Kotlin
- **构建**: Gradle 8.5 / Android Gradle Plugin 8.2.0
- **JDK**: 21 (D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle)
- **Android SDK**: D:\Tools\DevTools\Android\Sdk
- **关键依赖**: ViewModel, LiveData, Coroutines, ViewBinding, Material, RecyclerView, SwipeRefreshLayout
- **最低 SDK**: 26, 目标 SDK: 34

## 目录结构
```
ClipboardMerger/
├── android/
│   ├── app/
│   │   ├── src/main/java/com/example/clipboardmerger/
│   │   │   ├── MainActivity.kt                  # 主界面，剪贴板管理
│   │   │   ├── ClipboardInputMethodService.kt   # IME 输入法服务，内嵌剪贴板面板
│   │   │   ├── ClipboardService.kt              # 后台剪贴板监听服务
│   │   │   ├── ClipboardViewModel.kt            # ViewModel，数据绑定
│   │   │   ├── ClipboardRepository.kt           # 数据仓库层
│   │   │   ├── ClipboardItem.kt                 # 剪贴项数据模型
│   │   │   ├── ClipboardAdapter.kt              # 主界面 RecyclerView 适配器
│   │   │   ├── ImeClipboardAdapter.kt           # IME 面板 RecyclerView 适配器
│   │   │   ├── GitHubHelper.kt                  # GitHub Release 检查更新
│   │   │   └── Logger.kt                        # 日志工具类（文件日志 + 自动清理）
│   │   └── src/main/res/                        # 布局、字符串资源
│   ├── build.gradle.kts                         # Gradle 根构建脚本
│   ├── settings.gradle.kts                      # Gradle 设置
│   ├── gradle.properties                        # Gradle 属性
│   ├── version.properties                       # 版本号真源
│   └── local.properties                         # Android SDK 本地路径
├── harmony/                                     # 鸿蒙版代码
├── scripts/
│   ├── build.bat                                # Android 一键构建脚本
│   ├── build-harmony.bat                        # 鸿蒙一键构建脚本
│   ├── clean.bat                                # 清理构建产物（Android + 鸿蒙）
│   ├── gh-release.bat                           # 单独补发 GitHub Release
│   ├── deploy-harmony.bat                       # 鸿蒙版装机脚本 (hdc)
│   └── tools/
│       ├── tee-log.ps1                          # 日志 tee 包装器
│       ├── build-info.js                        # 鸿蒙构建信息
│       └── harmony-version.js                   # 鸿蒙版本号工具
└── memory-bank/                                 # 知识库
```

## 关键约定

### 构建命令
- **完整构建**: 通过 `scripts\build.bat` 执行（含 git 提交/推送/打 tag/`gh release create`）
  - `scripts\build.bat` — 构建 + 递增版本 + GitHub Release
  - `scripts\build.bat release` — 同双击
  - `scripts\build.bat setup` — 安装 Android SDK 组件
  - `scripts\build.bat clean` — 清理构建产物
- **自测编译（不推送）**: 直接跑 Gradle 命令，禁止跑 `scripts\build.bat`（会真的 push + 发 Release）
  ```cmd
  set JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle
  set ANDROID_HOME=D:\Tools\DevTools\Android\Sdk
  set ANDROID_SDK_ROOT=D:\Tools\DevTools\Android\Sdk
  set "PATH=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin;D:\Tools\DevTools\gradle\gradle-8.5\bin;%PATH%"
  cd /d "d:\WorkSpace\test\ClipboardMerger\android"
  call gradle assembleDebug & exit
  ```
  **关键**：`gradle` 是 `.bat` 文件，必须用 `call` 调用，否则控制权转移后 `& exit` 不会执行，终端无法自关闭。
- **单独补发 Release**: `scripts\gh-release.bat`（以最后一个提交为目标，不编译 / 不改版本，`check` = 只读预检）
- **版本号**: `version.properties` 是唯一真源，构建时自动递增小版本号

### 代码规范
- 使用 Kotlin 标准库函数
- 日志使用 `Logger` 工具类，支持文件日志（`/JianJi/` 目录下），自动清理 7 天前日志
- 日志开关通过 SharedPreferences `clipboard_merger_settings` 的 `log_enabled` 键控制
- IME 服务与主应用通过 `ClipboardRepository` 共享剪贴数据
- 剪贴板监听需处理 `selfUpdating` 标记避免循环更新

### 交流约定（强制）
- 所有思考、分析、回答必须使用中文
- 代码注释可使用中文或英文，但面向用户的界面文字必须使用中文

### 终端管理（强制）
- **终端标签名**：`.vscode/settings.json` 配置 `"terminal.integrated.tabs.title": "剪集"`，所有新终端标签统一显示为 `剪集`。
- **终端内容标识（必须）**：每个新终端首条命令必须是标识头：
  ```cmd
  echo === task-N-用途 ===
  ```
  - `N` 为递增序号（从 1 开始，本次请求范围内唯一）
  - `用途` 为简短英文描述（如 build、git、test）
- **终端自关闭（强制）**：由于 `target_terminal` 复用不生效（每次必开新终端），唯一可靠的清理方式是让终端自己关闭自己 —— 每条命令末尾加 `& exit`：
  ```cmd
  echo === task-1-git === && cd /d "d:\..." && git status & exit
  ```
  构建命令用 `.bat` + `Start-Process` 异步启动（bat 末尾加 `exit`），启动命令也加 `& exit`。
- **禁止主动杀进程**：`taskkill /f /im cmd.exe` 会误伤用户自己的 cmd；基于 RunCommand 的杀进程方案（获取 PID → taskkill）同样会开新终端，越清越多。仅依赖 `& exit` 自关闭。

### 临时文件管理（强制）
- 所有中间产物（命令输出、临时脚本、状态/轮询文件、探针日志、临时 JSON / CSV）全写 `tmp\`
- 每完成一个用户请求后，清理本次产生的临时文件：`rmdir /s /q tmp`
- `tmp\` 被 `.gitignore` 忽略（`/tmp/`），可放心当垃圾桶

### 知识库管理
- 知识库位于 `memory-bank/`，索引文件 `memory-bank/README.md`
- 开工读索引 → 只读命中条目；收工照 `memory-bank/WRITING.md` 回填
- 禁止 `read all` 知识库、禁止扫全仓库

### 命令等待
- 在终端执行命令后必须等待命令执行完成，不要命令一发出就立刻查看输出并断定执行失败

## 常用操作
- **编译检查**: `gradle assembleDebug`（不推送，不自增版本）
- **完整构建发布**: `scripts\build.bat`（含 git 提交/推送/打 tag/GitHub Release）
- **清理构建缓存**: `scripts\build.bat clean` 或手动删除 `build/` 目录和 `app/build/` 目录
- **安装 SDK 组件**: `scripts\build.bat setup`

## 项目记忆
- Git 仓库位于 `d:\WorkSpace\test\ClipboardMerger`，所有代码变更通过 git 管理
- 版本号由 `version.properties` 管理，`scripts\build.bat` 自动递增
- GitHub Release 仓库: `xiaobailong/ClipboardMerger`