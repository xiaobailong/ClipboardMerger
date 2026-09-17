# 剪贴板收集器 (ClipboardMerger)

一个 Android 剪贴板历史记录收集工具，通过注册系统输入法（IME）获取后台剪贴板监听权限，解决 Android 10+ 对普通应用后台读取剪贴板的限制。支持将收集到的内容通过 GitHub API 同步到远程仓库。

---

## 目录

- [功能特性](#功能特性)
- [技术原理](#技术原理)
- [APP 使用说明](#app-使用说明)
  - [首次使用](#首次使用)
  - [日常使用](#日常使用)
  - [IME 键盘操作](#ime-键盘操作)
  - [要切换回正常键盘](#要切换回正常键盘)
  - [GitHub 同步功能](#github-同步功能)
  - [版本标识](#版本标识)
- [项目构建说明](#项目构建说明)
- [日志与调试](#日志与调试)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [权限说明](#权限说明)
- [常见问题 (FAQ)](#常见问题-faq)
- [已知限制](#已知限制)

---

## 功能特性

- **剪贴板历史记录** — 自动收集所有复制到剪贴板的文本内容
- **后台监听** — 输入法模式持续监听，App 前台时由后台服务补充
- **合并粘贴** — 选中多条记录，一键合并到剪贴板
- **批量粘贴** — 在 IME 键盘中一键将所有收集内容粘贴到目标应用
- **单条粘贴** — 在 IME 键盘中粘贴最近一条剪贴板内容
- **一键清空** — IME 键盘中一键清空系统剪切板并清除全部收集记录
- **滑动删除** — 列表项左滑快速删除
- **GitHub 同步** — 支持将文本内容拉取/保存到 GitHub 仓库的指定文件，自动处理 Base64 编解码和 SHA 版本控制
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
| **删除** | 删除当前输入框中选中的文字 |
| **切换** | 单击直接切换到指定输入法（如小艺输入法），长按弹出系统键盘选择器 |
| **清空** | 一键清空系统剪切板内容并清除所有收集记录 |

### 要切换回正常键盘

多种方式：
- 在 IME 键盘上**单击「切换」**直接跳转到指定输入法
- 在 IME 键盘上**长按「切换」**弹出输入法选择器
- 在 App 主界面顶部点状态条，选择其他键盘
- 系统设置 → 语言和输入法 → 更改默认键盘

### GitHub 同步功能

App 内有两个 Tab 页：**「剪切板」** 和 **「GitHub」**，切换到 GitHub Tab 即可使用远程文件同步。

#### 首次配置

1. 点击 GitHub Tab 中的 **「设置」** 按钮
2. 填写以下信息：
   - **仓库地址**：例如 `https://github.com/用户名/仓库名` 或 `https://github.com/用户名/仓库名.git`
   - **Token**：GitHub Personal Access Token（需要在 GitHub Settings → Developer settings → Personal access tokens → Tokens(classic) 中生成，勾选 `repo` 权限）
   - **文件路径**：仓库中要读写的文件路径，例如 `src/data/tmp.txt`
3. 点击 **「保存」**

#### 拉取文件

1. 点击 **「编辑」** 按钮
2. App 会通过 GitHub API（`GET /repos/{owner}/{repo}/contents/{path}`）拉取文件内容
3. 内容加载到编辑框中，可自由编辑
4. **注意**：此操作使用系统代理（WiFi 代理 / VPN / Clash 等），确保网络能访问 GitHub API

#### 保存文件（即推送）

1. 编辑框中输入/修改内容后，点击 **「保存」** 按钮
2. App 先 `GET` 获取文件当前 SHA，再通过 `PUT` 请求更新文件
3. 保存成功后会自动生成 commit 信息 `"Update via ClipboardMerger"`
4. **保存 = 推送**：GitHub REST API 的 PUT 操作会直接更新仓库文件，无需额外 git push
5. 支持系统代理，自动检测并使用配置的代理连接

#### 状态提示

底部状态栏会显示操作状态：
- `正在从GitHub拉取文件…` — 正在获取文件
- `文件加载成功 (N 字符)` — 拉取成功
- `正在保存到GitHub…` — 正在保存
- `保存成功` — 保存/推送成功
- `加载失败: xxx` / `保存失败: xxx` — 错误信息

### 版本标识

App 主界面标题栏显示当前版本号（如 `v1.29`），与 `version.properties` 中的 `versionName` 一致。每次执行 `build.bat` 会自动递增 `versionCode`，方便区分不同构建版本。

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
versionCode=27
versionName=1.26
```

每次执行 `build.bat` 会自动递增 `versionCode`。

---

## 日志与调试

日志文件保存在设备外部存储：
```
/storage/emulated/0/Download/ClipboardMerger/clipboard_merger_log_YYYY-MM-DD.txt
```

日志记录内容：
- 服务启停状态
- 剪贴板捕获事件
- IME 键盘操作
- GitHub API 请求/响应详情
- 构建信息（SDK 版本、设备型号、应用版本等）
- 错误和异常详情

日志按天分割，自动清理 7 天前的旧日志。

查看日志：
```bash
adb pull /sdcard/Download/ClipboardMerger/ .
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
│       │   ├── MainActivity.kt                # 主界面（含 Tab 切换和 GitHub 操作回调）
│       │   ├── ClipboardService.kt            # 后台剪贴板监听服务
│       │   ├── ClipboardInputMethodService.kt # 输入法服务（IME）
│       │   ├── ClipboardRepository.kt         # 本地存储（JSON 文件，最多 5000 条）
│       │   ├── ClipboardViewModel.kt          # ViewModel 数据管理
│       │   ├── ClipboardAdapter.kt            # 列表适配器
│       │   ├── ClipboardItem.kt               # 数据模型
│       │   ├── GitHubHelper.kt                # GitHub API 交互（拉取/保存文件）
│       │   └── Logger.kt                      # 日志工具
│       └── res/
│           ├── layout/
│           │   ├── activity_main.xml           # 主界面布局（含 TabLayout）
│           │   ├── content_github.xml          # GitHub Tab 页面布局
│           │   ├── dialog_github_settings.xml  # GitHub 设置弹窗布局
│           │   ├── ime_view.xml                # IME 键盘布局
│           │   └── item_clipboard.xml          # 列表项布局
│           ├── values/
│           │   ├── strings.xml                 # 字符串资源
│           │   ├── colors.xml                  # 颜色定义
│           │   └── themes.xml                  # 主题定义
│           ├── xml/
│           │   └── input_method_config.xml     # 输入法配置
│           └── drawable/
│               └── ic_launcher_foreground.xml  # 启动图标
```

---

## 技术栈

| 类别 | 技术 |
|---|---|
| 语言 | Kotlin |
| 架构 | MVVM + Repository |
| UI | ViewBinding + Material Design (TabLayout) |
| 列表 | RecyclerView + ItemTouchHelper |
| 输入法 | InputMethodService |
| 后台服务 | Service（非前台） |
| 网络请求 | HttpURLConnection + 系统代理检测 |
| 数据远程同步 | GitHub REST API v3（Base64 编解码、SHA 版本控制） |
| 异步处理 | Kotlin Coroutines |
| 构建 | Gradle 8.5 + AGP 8.2.0 |

---

## 权限说明

| 权限 | 用途 |
|---|---|
| `INTERNET` | 访问 GitHub API 进行文件拉取和保存 |
| `WRITE_EXTERNAL_STORAGE` (maxSdk=28) | 仅 Android 9 以下，用于写入日志文件 |
| `BIND_INPUT_METHOD` | 注册为系统输入法（系统级权限） |

---

## 常见问题 (FAQ)

### Q: 为什么设为默认输入法后仍然收不到剪贴板内容？

1. 确保「剪贴板收集器」是**当前默认输入法**（不是仅"已启用"），主界面顶部提示条应显示绿色「已激活 ✅」
2. 部分国产手机（小米/华为/OPPO/vivo）需要在「设置 → 应用管理 → 剪贴板收集器」中授予**「后台运行」**或**「自启动」**权限
3. 检查是否开启了省电模式，部分机型的省电模式会冻结后台 IME 服务

### Q: IME 键盘的「粘贴」按钮为什么没反应？

「粘贴」按钮粘贴的是**系统剪贴板中当前的内容**，而不是历史列表中的内容。如果系统剪贴板为空（或被其他应用清空），则无法粘贴。如需粘贴历史记录，请使用 **「全部粘贴」** 按钮。

### Q: GitHub 同步失败，提示 "HTTP 401" 或 "Bad credentials"？

1. Token 可能已过期或被撤销，请重新生成 GitHub Personal Access Token
2. 确保 Token 勾选了 `repo` 权限（对于私有仓库）
3. Token 格式应为 `ghp_xxxx`（classic token）或 `github_pat_xxxx`（fine-grained token）

### Q: GitHub 同步提示 "HTTP 404"？

1. 仓库不存在或仓库地址拼写错误
2. 文件路径不正确（注意大小写和路径分隔符）
3. Token 无权访问该仓库（检查是否授权了正确的组织/仓库）

### Q: GitHub 拉取文件后内容是乱码？

GitHub API 返回的是文件的 Base64 编码内容，App 会自动解码。如果出现乱码，说明目标文件可能不是 UTF-8 编码的文本文件。建议确保 GitHub 仓库中的文件为 UTF-8 纯文本格式。

### Q: 剪贴板记录会保存多久？

本地记录保存在 SharedPreferences 中，最多保留 **5000 条**，已满时最旧的记录会被移除。只要不卸载 App 或手动清空，数据会一直保留。

### Q: 手机重启后剪贴板收集器还能工作吗？

IME 服务会在系统启动后自动恢复，但建议在开机后**打开一次 App** 以确保后台服务和剪贴板监听正常运行。部分国产手机重启后需要手动启动 App 才能恢复后台服务。

### Q: 为什么 App 内能看到记录，但数量比预期的少？

1. **去重机制**：如果连续复制相同内容，只保留最早的一条
2. **数量上限**：超出 5000 条后自动丢弃最旧记录
3. **后台限制**：当 App 不在前台且 IME 也不是默认输入法时，Android 10+ 无法监听到剪贴板变化

---

## 已知限制

### Android 10+ 后台剪贴板限制

Google 从 Android 10 开始严格限制后台应用读取剪贴板。本 App 通过注册 IME 服务绕过此限制，但以下场景剪贴板监听可能失效：

- **IME 不是当前默认输入法**：此时只有 App 在前台时才能通过后台服务 + OnPrimaryClipChangedListener 监听
- **App 不在前台且 IME 未被触发**：后台监听可能被系统冻结
- **设备进入深度休眠**：系统可能暂停 IME 服务

### 国产 ROM 兼容性

| 厂商 | 注意事项 |
|---|---|
| 小米 (MIUI/HyperOS) | 需在「设置 → 应用管理 → 剪贴板收集器」中开启**「自启动」**，并关闭省电策略中的**「智能限制」** |
| 华为 (HarmonyOS/EMUI) | 需开启**「允许后台活动」**，并在「应用启动管理」中设为**「手动管理」**，同时勾选自启动、关联启动、后台活动 |
| OPPO/一加 (ColorOS) | 需在「设置 → 电池 → 应用耗电管理」中关闭后台冻结 |
| vivo/OriginOS | 需在「设置 → 电池 → 后台高耗电」中开启该 App 的后台权限 |
| 三星 (OneUI) | 需在「设置 → 应用程序 → 剪贴板收集器 → 电池」中设为**「不受限制」** |

### 网络同步限制

- GitHub API 有[速率限制](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)：未认证请求每小时 60 次，使用 Token 认证后每小时 5000 次
- 保存文件时每次都会发起两个 HTTP 请求（先 GET 取 SHA，再 PUT 写入）
- 系统代理检测依赖于 Android 系统的 `ProxySelector`，部分 VPN 应用可能不被识别

### 数据存储限制

- 剪贴板历史记录存储在 `SharedPreferences` 的 JSON 字符串中，总容量受系统限制（通常几 MB）
- 单条剪贴板内容过大（如超过 1MB 的文本）可能导致存储失败或性能问题
- 日志文件按天保存，保留 7 天，存储在外部公共目录，可能被用户手动清理