# 剪贴板收集器 (ClipboardMerger)

一个 Android 剪贴板历史记录收集工具，通过注册系统输入法（IME）获取后台剪贴板监听权限，解决 Android 10+ 对普通应用后台读取剪贴板的限制。

---

## 功能特性

- **剪贴板历史记录** — 自动收集所有复制到剪贴板的文本内容
- **后台监听** — 输入法模式持续监听，App 前台时由后台服务补充
- **合并粘贴** — 选中多条记录，一键合并到剪贴板
- **批量粘贴** — 在 IME 键盘中一键将所有收集内容粘贴到目标应用
- **单条粘贴** — 在 IME 键盘中粘贴最近一条剪贴板内容
- **清空剪切板** — IME 键盘中一键清空系统剪切板内容
- **滑动删除** — 列表项左滑快速删除
- **调试日志** — 完整的日志输出，方便排查问题

---

## 技术原理

Android 10+ 严格限制后台应用读取剪贴板，只有**当前默认输入法**才能无限制获取剪贴板内容。本 App 利用这一机制：注册一个输入法服务（`InputMethodService`），当用户将其设为默认键盘后，即可在后台持续监听剪贴板变化。

```
┌─────────────────────────────────────────────────┐
│  其他 App 复制内容                                │
│       │                                          │
│       ├── ClipboardInputMethodService (IME)      │
│       │       └── 后台监听，存入 Repository       │
│       │                                          │
│       ├── ClipboardService (后台服务)             │
│       │       └── App 前台时监听，存入 Repository │
│       │                                          │
│       └── MainActivity (App 内)                  │
│               ├── reloadFromRepository()  ← 加载 │
│               ├── readCurrentClipboard()  ← 即时 │
│               └── BroadcastReceiver       ← 刷新 │
└─────────────────────────────────────────────────┘
```

---

## APP 使用说明

### 首次使用

1. 安装 APK 后打开「剪贴板收集器」
2. 界面顶部会显示 **「输入法: 未激活 ⚠️」** 黄色提示条
3. **点击该提示条**，系统弹出键盘选择器
4. 在键盘列表中**选择「剪贴板收集器」**
5. 提示条变绿：**「输入法: 已激活 ✅ — 后台监听中」**
6. 此时去任意 App 中复制文字，剪贴板内容就会被自动收集

### 日常使用

| 操作 | 说明 |
|---|---|
| 刷新列表 | 打开 App 自动加载，或下拉刷新 |
| 合并选中 | 勾选多条记录 → 点击「合并选中」→ 合并内容写入剪贴板 |
| 删除单条 | 列表项左滑 → 点击红色「删除」 |
| 清空全部 | 点击「清空全部」按钮 |

### IME 键盘操作

当剪贴板收集器是默认输入法时，在任意文本框中弹出键盘：

| 按钮 | 功能 |
|---|---|
| **粘贴** | 将最近一条剪贴板内容粘贴到当前输入框 |
| **全部粘贴** | 将所有收集到的内容按时间倒序拼接，一次性粘贴 |
| **切换** | 切回系统默认键盘 |
| **清空系统剪切板** | 一键清空系统剪切板中的内容 |

### 要切换回正常键盘

三种方式：
- 在 IME 键盘上点 **「切换」** 按钮
- 在 App 主界面顶部点状态条，选择其他键盘
- 系统设置 → 语言和输入法 → 更改默认键盘

---

## 项目构建说明

### 环境要求

| 工具 | 版本 | 说明 |
|---|---|---|
| JDK | 21+ | 推荐 Oracle JDK 21 |
| Android SDK | API 34 | 需安装 `platforms;android-34` 和 `build-tools;34.0.0` |
| Gradle | 8.5 | 通过 wrapper 自动下载 |
| Android Gradle Plugin | 8.2.0 | 项目依赖 |
| Kotlin | 1.9.20 | 项目依赖 |

### 快速构建

项目根目录提供了 `build.bat` 一键构建脚本：

```bash
# 构建 APK（自动递增版本号）
build.bat

# 首次使用：安装缺失的 SDK 组件
build.bat setup

# 清理构建产物
build.bat clean
```

### 手动构建

如果 build.bat 不可用，可按以下步骤手动构建：

1. 确保 `JAVA_HOME` 和 `ANDROID_HOME` 环境变量已配置

2. 首次使用需安装 SDK 组件：
   ```bash
   sdkmanager "platforms;android-34" "build-tools;34.0.0"
   ```

3. 构建 APK：
   ```bash
   cd ClipboardMerger
   gradlew assembleDebug
   ```

4. APK 输出路径：
   ```
   app\build\outputs\apk\debug\ClipboardMerger-v{version}-{code}.apk
   ```

### 自定义构建环境路径

编辑 `build.bat` 和 `gradle.properties`，修改以下变量：
- `JAVA_HOME` — JDK 安装路径
- `ANDROID_HOME` — Android SDK 路径
- `org.gradle.java.home` — Gradle 使用的 JDK 路径

### 版本管理

项目版本号通过 `version.properties` 管理：
```properties
versionCode=17
versionName=1.16
```

每次执行 `build.bat` 会自动递增 `versionCode`。

---

## 日志与调试

日志文件保存在设备外部存储：
```
/storage/emulated/0/Download/ClipboardMerger_log.txt
```

日志记录内容：
- 服务启停状态
- 剪贴板捕获事件
- IME 键盘操作
- 构建信息（SDK 版本、设备型号等）

查看日志：
```bash
adb pull /sdcard/Download/ClipboardMerger_log.txt .
```

---

## 项目结构

```
ClipboardMerger/
├── README.md                          # 本文件
├── build.bat                          # 一键构建脚本
├── clean.bat                          # 清理脚本
├── version.properties                 # 版本号配置
├── build.gradle.kts                   # 根项目构建配置
├── settings.gradle.kts                # 项目设置
├── gradle.properties                  # Gradle 属性
├── app/
│   ├── build.gradle.kts               # App 模块构建配置
│   ├── proguard-rules.pro             # 混淆规则
│   └── src/main/
│       ├── AndroidManifest.xml         # 应用清单
│       ├── java/com/example/clipboardmerger/
│       │   ├── MainActivity.kt                # 主界面
│       │   ├── ClipboardService.kt            # 后台剪贴板监听服务
│       │   ├── ClipboardInputMethodService.kt # 输入法服务（IME）
│       │   ├── ClipboardRepository.kt         # 本地存储（JSON 文件）
│       │   ├── ClipboardViewModel.kt          # ViewModel 数据管理
│       │   ├── ClipboardAdapter.kt            # 列表适配器
│       │   ├── ClipboardItem.kt               # 数据模型
│       │   └── Logger.kt                      # 日志工具
│       └── res/
│           ├── layout/
│           │   ├── activity_main.xml           # 主界面布局
│           │   ├── ime_view.xml                # IME 键盘布局
│           │   └── item_clipboard.xml          # 列表项布局
│           ├── values/
│           │   ├── strings.xml                 # 字符串资源（中文）
│           │   ├── colors.xml                  # 颜色资源
│           │   └── themes.xml                  # 主题
│           └── xml/
│               └── input_method_config.xml     # 输入法配置
```

---

## 技术栈

| 类别 | 技术 |
|---|---|
| 语言 | Kotlin |
| 架构 | MVVM + Repository |
| UI | ViewBinding + Material Design |
| 列表 | RecyclerView + ItemTouchHelper |
| 输入法 | InputMethodService |
| 后台服务 | Service（非前台） |
| 构建 | Gradle 8.5 + AGP 8.2.0 |

---

## 权限说明

| 权限 | 用途 |
|---|---|
| `WRITE_EXTERNAL_STORAGE` (maxSdk=28) | 仅 Android 9 以下，用于写入日志文件 |
| `BIND_INPUT_METHOD` | 注册为系统输入法（系统级权限） |