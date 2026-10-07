# 已排查问题（issues-solved）

> 上限 12KB（超了照 `WRITING.md` §3 归档）。每条必填：症状 / 复发判据 / 根因 / 证据 / 修法 / 反例。
> 编号只增不改，新条目取当前最大号 +1。模板见 `WRITING.md` §1。

## ISSUE-001 `build.bat` 构建日志 `build\logs\build_<ts>.log` 写不进去
- 状态: 已修复（2026-09-22，commit `d21ff87` → `f9bc43c` → `bccd4ca`）
- 症状 / 现场: 控制台有输出，日志只有首行 / 只有空行 / 整段缺失；中途留下 `build\logs\_logpath.tmp` 残留。
- 复发判据:
  ```bat
  findstr /n "tee-log.ps1" build.bat
  findstr /n "logpath" build.bat
  ```
  期望：第一条命中 `:init_log` 里的 `powershell ... -File "%_CM_TEE%" -Log ...`（tee 链路在，见 `ADR-010`）；
  第二条 **0 命中**。构建**进行中** `type build\logs\build_<ts>.log` 能看到已产出的行（逐行落盘）。
  出现 `2>&1 | powershell`、`-Command "... Out-File ..."`、`_logpath.tmp` 这类写法 ⇒ 复发。
- 根因（三层，逐层修掉）: ①`if not defined (...)` 括号块里 `%_CM_LOG_TS%` / `%_CM_LOGFILE%` 解析期展开为空
  ⇒ 首行变 `[]`、重定向目标为空路径；②改用管道喂 `powershell -Command "... Out-File -Append ..."`
  ⇒ `-Command` 里的路径同样被预展开（且长 `-Command` 在本机不可靠）；③即便路径传对，
  管道 + `Out-File`/`Add-Content` 逐行追写**依然丢内容**。
- 修法: `build.bat` 顶部 `if not defined _CM_LOG_ACTIVE goto :init_log`（跳出括号块，不用 `( )`）+
  `call "%~f0" %* 1>> "%_CM_LOGFILE%" 2>&1` + 紧邻一行 `set _CM_BUILD_RESULT=%ERRORLEVEL%` +
  首行用 `powershell -Command "[System.IO.File]::WriteAllText(..., UTF8Encoding($true))"` 写 UTF-8 BOM。
- 反例 / 易误判: 认定"日志是空文件 ⇒ 构建没跑"（其实构建跑了，见 `PIT-016`）；
  把 `> "%LOG%"` 写在括号块里；用管道给 PowerShell 做 tee。
- 二次优化（2026-09-23）: 控制台实时性改由 `tools\tee-log.ps1` tee 包装器解决 —— 逐行「先写文件（AutoFlush）→ 再回显」，
  被包装脚本路径/参数走 `_CM_SELF` / `_CM_ARGS`（见 `ADR-010`）；老路径保留为缺脚本时的降级分支（`:log_legacy`）。
- 相关: `PIT-007` / `PIT-012` / `PIT-013` / `ADR-003`；
  **三次失败方案的完整过程分析见 `archive/issues-solved-archive.md`**
- 首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（二次优化为 tee 包装器，判据已同步更新）

## ISSUE-002 构建失败也会消耗一个 `versionCode`（版本号跳号）
- 状态: 未修复（已知行为，影响仅跳号，可接受）
- 症状 / 现场: 编译失败的下一轮构建成功发布后，`versionCode` 比上一版 **+2**；失败也留下 `version.properties` 改动。
- 复发判据: 构建失败后 `git --no-pager diff -- version.properties` 仍显示 `versionCode` 已 +1。
- 根因: 递增排在编译之前且失败不回滚 —— `build.bat` `:build` 的 `[1/5]`（106-113 行）与
  `:release` 的 `[3/6]`（272-288 行）都先 `incrementVersion`；`app/build.gradle.kts:58-75` 直接写文件。
- 修法: 未修。要连续号就把 `incrementVersion` 挪到 `assembleDebug` 成功之后
  （注意发布流程要读 `versionName`/`versionCode`，位置要一起调）。
- 反例 / 易误判: 把跳号当成"脚本跑了两次 / Gradle 缓存问题"的证据。
- 相关: `ADR-005`　首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（代码位置未变）

## ISSUE-003 全局日志开关关闭后，进程重启仍有日志输出
- 状态: 已修复（2026-09-23）
- 症状 / 现场: 设置里关掉“日志输出”当场生效；但进程被回收 / 重启手机 / 输入法服务被系统重新拉起后，
  `Download/JianJi/jianji_log_<date>.txt` 又在增长、Logcat 又在刷。
- 复发判据: 关闭开关 → 完全杀掉进程（`adb shell am force-stop com.example.clipboardmerger`）→ 切换一次输入法触发服务启动 →
  看当天日志文件是否又出现 `=== Log started ===`。静态判据（5 秒）:
  ```bat
  findstr /n "readEnabledFromPrefs" app\src\main\java\com\example\clipboardmerger\Logger.kt
  ```
  期望：`init()` 内有 1 处命中。0 命中 ⇒ 开关又只活在内存里，复发。
- 根因: 开关只是内存字段 `private var enabled = true`（`Logger.kt:27`），唯一读持久化设置的地方在 Activity
  （旧 `MainActivity.kt:569-573 loadLogSetting()`）。`ClipboardService` / `ClipboardInputMethodService` 只调 `Logger.init()`
  （`ClipboardService.kt:49`、`ClipboardInputMethodService.kt:64`）⇒ 新进程里由服务先初始化时，开关回到默认 `true`。
- 修法: 开关收口到 `Logger`：`const PREFS_NAME / KEY_LOG_ENABLED`（`Logger.kt:14-16`）+ `init()` 里
  `enabled = readEnabledFromPrefs(appCtx)`（`Logger.kt:39`、`58-65`）+ 唯一写入口 `setEnabled(context, enabled)`
  （写内存 + `SharedPreferences` 持久化，`Logger.kt:112-129`）；开启时若 `logFile == null` 补建日志文件。
  同时删掉 Activity 侧的内存态 setter / 本地常量（旧 API `setEnabled(Boolean)` 已不存在）。
- 加强（2026-09-23）: 关闭时**连 Download 目录都不再创建** —— `init()` 只在 `enabled` 时调 `trySetupLog()`，
  否则只算预期路径（`expectedLogPath()`，不 `mkdir`）；`setEnabled(context, true)` 才补建；UI 用 `isLogFileActive()`
  加"（当前未创建）"提示。判据：关开关 → 杀进程重启 → `adb shell ls /sdcard/Download/JianJi` 应为 `No such file or directory`。
- 反例 / 易误判: 以为“Activity 里 `loadLogSetting()` 已经设过 ⇒ 全局都关了”（服务/输入法可能在新进程里先跑）；
  以为“文件里还有新行 ⇒ 开关没生效”（其实要区分“关掉之后写入的行”和“重启后被重新打开”）。
- 相关: `ADR-008`；首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（静态判据 + `assembleDebug` 通过）

## ISSUE-004 `build.bat` 构建完不提交、不打标签、不发 Release（整块被解析中止）
- 状态: 已修复（2026-09-23）
- 症状 / 现场: 日志走到 `提交版本变更...` 就没了；`version.properties` 已改但没 commit；远端只有旧版本
  （`gh release list` 只有 v1.42 / v1.39；`git ls-remote --tags origin` 也只有 v1.39 / v1.42；`origin/main` 停在 `bccd4ca`）。
- 复发判据（纯 ASCII，避开 `findstr` 中文假阴性，见 `PIT-017`）:
  ```bat
  findstr /c:"call \"%GH_EXE%\"" build.bat
  findstr /c:"call :gh_release" build.bat
  ```
  期望：第 1 条 **0 命中**（gh 只准在子过程里直接调用）；第 2 条 **4 命中**（`:build` / `:release` 各 2 个分支）。
  命中数变化 ⇒ 有人又把 `gh release create ...` 内联回 `if (...)` 块里（裸括号的温床）。
  （`build\logs\build_20260922_231449.log:120`）。
- 根因: `if errorlevel 1 ( ... ) else ( ... )` 块里写了未转义的半角括号（旧 `build.bat:232` / `:375`
  `echo [警告] Release创建失败(可能已存在)，请手动检查`）；cmd 把那个 `)` 当成块结束符 ⇒ **整个 if/else 块解析失败**
  ⇒ 块内 `git commit` / `push` / `tag` / `gh release` 一行都没执行，批处理当场终止（同族坑 `PIT-005`）。
- 修法: 见 `ADR-009` —— ①去掉 echo 里的裸括号；②gh 逻辑抽成 `:check_gh` / `:gh_release` 子过程（`build.bat:382-439`），
  调用处只 `call :gh_release` + `if errorlevel 1` 硬失败；③子过程用 `exit /b 0/1` 明确退出码（防 `PIT-013`）。
- 验证（抽段测试，临时文件已删）: 把 `:check_gh` / `:gh_release` 原文抽到 `tmp\gh_test.bat` 跑 7 个用例 ——
  假仓库 create 失败能回传 1；空 / 不存在的 APK 被拦；`"C:\Program Files\GitHub CLI\gh.exe"` 带空格路径可执行；
  已存在 Release 的 `release view` 返回 0、不存在的返回非 0；全文括号配平 56/56、运行余额不出现负数。
- 反例 / 易误判: 以为“gh 没登录 / 仓库地址写错”（实测 `gh auth status` 正常、`--repo` 与 remote 一致）；
  以为“Release 已存在所以失败”（这一步根本没执行到）。
- 相关: `PIT-005`、`PIT-013`、`PIT-023`、`ADR-009`；首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（抽段测试通过）

## ISSUE-005 `git push` 瞬断（`Connection reset … port 22`）导致发布中断，tag/Release 全没做
- 状态: 已规避（2026-09-23，`build.bat` 加 `:git_push` 重试；`gh-release.bat` 再加「远端标签已在 HEAD 就跳过 tag 推送」快路径 + `GH_PROXY` 代理）
- 症状 / 现场: 提交成功（`[main aaa7666] release: v1.52 (build 53)`）后 `Connection reset by 20.205.243.166 port 22`
  ⇒ `[错误] git push 失败！` ⇒ 退出，tag 与 Release 都没执行（本地多一个未推送提交）。同一轮 `检查 gh CLI` 还报过
  `[警告] gh 未登录或登录状态异常` —— 同样是网络瞬断（`gh auth status` 会联网校验 token）；事后复测 `gh auth status` 正常、
  `ssh -T git@github.com` 返回 `Hi xiaobailong!` ⇒ **不是凭据问题**。
- 复发判据: 构建日志出现 `Connection reset by … port 22` / `fatal: Could not read from remote repository`；
  修复后日志应是 `推送 <ref> ...`（必要时跟 `[重试 n/3]`），不再"一次失败即退出"。
- 根因: 本机到 github.com:22 时通时断；脚本原来一次失败就硬退出，没有重试，也没有可操作的提示。
- 修法: 新增 `:git_push <ref> [force]`（`build.bat:424-448`）：最多 3 次、间隔 3 秒；3 次全败才打印常见原因 +
  手工重试命令 + “改走 HTTPS: `gh auth setup-git && git remote set-url origin https://github.com/<repo>.git`”，再 `exit /b 1`。
  8 个推送点全部改用它；`:check_gh` 的自检失败改为打印 `gh auth status` 原文（区分 token 失效 / 网络）。
- 验证（假 git，临时文件已删）: `tmp\fakepath\git.bat` 可配置失败次数，抽 `:git_push` 原文跑两例 ——
  ①失败 1 次后成功 ⇒ 重试生效、返回 0；②连续失败 ⇒ 3 次尝试（force 分支带 `-f`）后打印指引并返回 1。
- 反例 / 易误判: 把 `gh 未登录` 当真（其实是联网自检失败）；把推送失败当脚本 bug（脚本只能重试，链路问题要换 HTTPS / 代理）。
- 相关: `ADR-009`、`ISSUE-004`；首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（假 git 用例通过）
- 追加（2026-09-23 实跑补发 v1.53）: ①SSH 侧会**卡死**（`git ls-remote` / `git push` 长时间无输出，不是快速报错退出），
  3 次重试 + `-f` 兜底也可能全败；②`gh` 的 HTTPS API 直连报
  `Post https://api.github.com/graphql: net/http: TLS handshake timeout`，**设 `http_proxy` / `https_proxy=http://127.0.0.1:7897` 后可用**
  （`curl -x` 探测：代理可达时 `proxy_api=200`，代理没起时 `000`）；③`gh-release.bat` 因此加了两条路：
  「远端标签已指向 HEAD ⇒ 跳过 tag + 推送」（判定走 `gh api`，不吃 SSH）+ `GH_PROXY` 代理注入 —— 本次即靠它完成发布：
  Release `v1.53`（原本是**草稿**，已 `--draft=false` 发布）+ APK `JianJi-v1.53-54.apk` 已上传。

## ISSUE-006 抽段测试把「主流程」当成子过程跑了 ⇒ 误建并推送真实 tag `v1.53`
- 状态: 已修复（2026-09-23，抽取脚本起点已改）
- 症状 / 现场: 假 `gh` 用例跑到 `check_gh` 时，输出里冒出**真实主流程**（`[2/6] 读取版本信息` …
  `Updated tag 'v1.53' (was 94f9621)` … `推送 v1.53 ...`）⇒ 本地多出 tag `v1.53`，**远端也被推上 `refs/tags/v1.53`**
  （tag 对象消息 `Release v1.53`，指向当时 HEAD `7c4e154`；据此与 `build.bat` 的 `Release vX - build N` 区分是谁建的）。
- 复发判据: ①抽取脚本自身断言：`firstline=:check_gh`，出现 `ERR: carve leaked main flow` 即复发；
  ②测试输出里**不该**出现 `[2/6]` / `Updated tag` / `推送 `；③`git tag --list` 在测试前后应完全一致。
- 根因: `$text.IndexOf(':check_gh')` 命中的是**主流程里的 `call :check_gh`**（早于 `:check_gh` 标签行）；
  切出来的正文 = 主流程 + 尾部子过程，且派发器 `goto :check_gh` 落到这个「伪标签」后顺序执行主流程 ⇒ 打 tag / push 全是真的
  （只有 `gh` 是假的，所以没建 Release）。
- 修法: ①起点改 `(?m)^:check_gh\s*$`；②加断言「首行 = `:check_gh`」「正文不含 `[2/6]`」「标签唯一」；
  ③测试用假 `git` 放 PATH 最前且 `tag` 一律 `exit /b 1`（兜底）；④抽取副本只做「行首 `"..."` → `call "..."`」的最小改写（`PIT-025`）。
- 反例 / 易误判: 以为「测试只调子过程、不会碰远端」；把非强制推送的 `already exists` 拒绝当成「远端本来就有这个 tag」
  （实际是同一事故**前一次**推送建的）；只看用例退出码（当时 9 个用例的退出码都「正常」）。
- 相关: `PIT-025`、`ADR-011`、`ADR-009`；首次记录: 2026-09-23 ／ 最近复核: 2026-09-23（改后 9 用例全过，无主流程泄漏）

## ISSUE-007 绑定App：输入法选择器不弹出 + 通知不悬浮（根因 = IMMS 的“当前焦点窗口”闸门）
- 状态: 已修复（v1.80，代码已改 + 编译通过，待真机复验） — 根因由 AOSP 源码定死（见下）
- 复发判据（静态，5 秒）: `findstr /n "onWindowFocusChanged" app\src\main\java\com\example\clipboardmerger\PickerActivity.kt`（期望命中）+ `findstr /n "bind_app_channel_v3" app\src\main\java\com\example\clipboardmerger\ClipboardService.kt`（期望命中）+ `findstr /n "PICKER_MIN_INTERVAL_MS" app\src\main\java\com\example\clipboardmerger\ClipboardService.kt`（期望命中）；出现“onCreate 里就直接调选择器”/ 渠道 ID 又回到 v1、v2 / 又用 2 分钟长冷却 ⇒ 复发。真机判据: 绑定抖音并开「显示在其他应用上层」→ 每次进入抖音都应弹出提醒卡片；日志出现 `showInputMethodPicker() called (source=auto, attempt=1)`
- 根因（AOSP 源码证据）: `InputMethodManagerService.canShowInputMethodPickerLocked()`（Android 12 / LineageOS 19.1 `InputMethodManagerService.java:3680-3693`）只在 ①`client == mCurFocusedWindowClient`（调用方就是“当前焦点窗口”）②或调用方 uid 拥有当前输入法 时才返回 true；否则 `showInputMethodPickerFromClient()`（同文件 `3696-3714`）只打一句 `Slog.w("Ignoring showInputMethodPickerFromClient of uid ...")` 后 return —— **应用侧无异常、无返回值**。而 `mCurFocusedWindowClient` 只在 `startInputOrWindowGainedFocus` 成功后赋值（同文件 `3503-3505`），也就是“窗口拿到焦点”之后。
  - 落在本项目: v1.78 / v1.79 都在 `PickerActivity.onCreate` 里（启动后约 8ms）就调 `showInputMethodPicker()`，此时窗口还没拿到焦点 ⇒ 调用必然被丢弃。不是华为独有的拦截（PIT-028 的旧结论按本条修正）。
- 证据（真机日志 `jianji_log_2026-10-01.txt`，v1.79 实跑；交接文档旧结论“未见 v1.79 运行记录”已过期）: `00:52:42.841 bind app notification sent for [抖音]` → 用户点通知 `00:53:01.517 PickerActivity: onCreate` → `.525 showInputMethodPicker()` 调用 → `00:53:03.109 destroyed`（1.5s 延迟到点），全程无异常、选择器不出现 ⇒ 与“被 IMMS 静默忽略”完全吻合。
- 修法（v1.80~v1.83）: ①`PickerActivity` 改成**可见**的半透明卡片页（`Theme.JianJi.Picker` + `activity_picker.xml`）：在 `onWindowFocusChanged(true)` 之后延迟 400ms **只自动调一次** `showInputMethodPicker()`（自动补调 = 先 hide 再 show，会把选择器闪掉，见 `PIT-028`）；附「弹出输入法选择器 / 打开系统输入法设置 / 关闭」三个兜底按钮；失焦 ≥1.5s 才判定“选择器弹过并已被关闭”而 `finish()`（极短失焦当抖动忽略），另加 60s 兜底自动关闭。　②（v1.80）通知换新渠道 ID + `setFullScreenIntent` + `USE_FULL_SCREEN_INTENT`（见 `ADR-012`）。　③（v1.83）渠道再换 `bind_app_channel_v3` 并**加声音**（EMUI 把无声音渠道当静默通知 ⇒ 没横幅，`PIT-031`），启动日志补 `hasSound` / `canDrawOverlays`。　④（v1.83）提醒门改成“**每次进入绑定 App 都能提醒一次**”（离开前台即重置，只留 15s 防抖），不再用 2 分钟冷却。　⑤（v1.83）授予「显示在其他应用上层」后**直接从服务 `startActivity` 拉起提醒卡片**（该权限同时是后台启动 Activity 的豁免条件），通知继续作为兜底。　⑥（v1.84，用户反馈“两层弹框”）提醒页默认**完全不可见**（透明窗口 + 卡片 `GONE`），只留“系统选择器”这一层；只有当 1.6s 后本页仍持有着窗口焦点（= 选择器被系统拦下）时才把兜底卡片显示出来。　⑦（v1.84）「更多」菜单新增**悬浮提醒权限**入口（显示当前状态 + 一键跳授权页）—— 华为不给横幅，必须让用户找得到这个开关。　⑧（v1.85）提醒改成**自绘悬浮气泡**（`BindAppBubble`：`WindowManager` + `TYPE_APPLICATION_OVERLAY` + `FLAG_NOT_FOCUSABLE`）并直接调 `Vibrator` 振一下，**绕开通知系统** ⇒ 静音 / 振动 / 免打扰下都能看到；通知只在“没有悬浮权限”时兜底。
  ②通知换新渠道 ID `bind_app_channel_v2`（HIGH + 振动 + `setShowBadge(true)`）并删掉老渠道 `bind_app_channel`（渠道属性创建后不可变，对同一 ID `delete+重建` 无效）；通知加 `setFullScreenIntent(intent, true)`（设备在用→悬浮横幅，息屏/锁屏→直接拉起提醒页）+ `USE_FULL_SCREEN_INTENT` 权限；③服务启动时打一行诊断 `notificationsEnabled / bindChannel / importance / shouldVibrate`（下次真机直接看这行）。
- 历史症状链（v1.75 → v1.79 版本演进，已归档）: v1.75 后台 `showInputMethodPicker()` 被吞 → v1.77 通知跳 `ACTION_INPUT_METHOD_SETTINGS`（打开的是设置页不是选择器）→ v1.78/v1.79 透明 `PickerActivity` + `deleteNotificationChannel`；原文见 `archive/issues-solved-archive.md`
- 涉及文件: `ClipboardService.kt`、`PickerActivity.kt`、`activity_picker.xml`、`themes.xml`、`colors.xml`、`strings.xml`、`AndroidManifest.xml`、`MainActivity.kt`
- 反例 / 易误判: ①把 `showInputMethodPicker()`“调用成功”当“已弹出”（它是 void，被忽略时零反馈）②把根因写成“华为拦截透明 Activity / finish 太快”（v1.78/v1.79 的旧结论）③以为 `deleteNotificationChannel` + 重建能改旧渠道属性。兜底（华为实在不行）: `Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)`。
- 相关: `PIT-028`、`PIT-029`、`PIT-030`、`PIT-031`、`ADR-012`（绑定App 的实现细节已并入该条；原 `handover-bind-app.md` 已删除，历史版本见 commit `dfd9e7d`..`1ba7d86`）　首次记录: 2026-10-01 ／ 最近复核: 2026-10-01（v1.82 真机复验：选择器时序已正常 —— `02:15:44.217 调用` → `.442 失焦` → `02:15:53 focus back after 9271ms, picker was shown`，选择器确实弹出并存活；剩两个问题已改：渠道无声音 ⇒ 无横幅（换 v3 + 声音，`PIT-031`）、2 分钟冷却 ⇒ 只有第一次提醒（改“每次进入提醒一次”）；另加「显示在其他应用上层」后直接拉起提醒卡片。出包 v1.83 / build 84；v1.83 真机复验：`canDrawOverlays=false` ⇒ 只能靠通知（横幅仍被 EMUI 吞掉），点通知后**提醒卡片与系统选择器同时在场 = “两层弹框”**（`02:26:13.456 调用` → `.599 失焦` → 1410ms 后焦点回来；另有 349ms / 846ms 两次），选择器停留时长偏短 ⇒ v1.84 改为“默认不可见、只留选择器一层 + 选择器没出来才显示兜底卡片”，并在更多菜单加悬浮权限入口。出包 v1.84 / build 85；v1.85：用户反馈“静音/振动/免打扰下完全没有提醒” ⇒ 判定通知（含全屏 Intent）这条路在华为上无解，改为**自绘悬浮气泡 + 直接振动**（`PIT-032`），出包 v1.85 / build 86）

## ISSUE-008 鸿蒙版：⋮→「皮肤」弹框只剩「关闭」按钮（分支被误删）；输入法状态条点出的是英文系统选择器
- 状态: 已修复（v1.100 已装机；⋮→皮肤 分支已恢复；状态条已按下述追加改为**只读**、输入法弹框已删除）　- 复发判据: `findstr /n "dialog === " harmony\entry\src\main\ets\pages\Index.ets` 必须列出 `'theme'` 分支（缺它 ⇒ 皮肤弹框又会只剩「关闭」按钮），且**不应**再出现 `'ime'` 分支（该弹框已按 `ADR-015` 删除）；`findstr /n "onClick" harmony\entry\src\main\ets\pages\Index.ets` 里 `topBar()` 内**不应**再有 onClick
- 症状: ①主界面顶部「输入法: 未激活」状态条点一下，弹出的输入法列表**全是英文标识**（看不出哪个是「剪集」）；②「⋮ → 皮肤」打开的弹框里**只有底部的「关闭」按钮**，没有任何皮肤选项。
- 根因: ①状态条调 `showImePicker()` → `inputMethod.getSetting().showOptionalInputMethods()`：系统选择器列的是输入法自身的英文标识（猜不到本地化口径），且该接口 API 18 起被官方标 deprecated（`@ohos.inputMethod.d.ts:424`，`@useinstead ohos.inputMethodList/InputMethodListDialog`）；②`Index.ets` 的 `dialogLayer()` 里**压根没有 `dialog === 'theme'` 分支** —— 菜单项仍写着 `this.dialog = 'theme'`，于是弹框主体为空、只剩共享的「关闭」行。误删来源: commit `bedd74d`（release harmony v1.99）在该文件删掉 152 行，`git diff bedd74d~1 bedd74d -- harmony/entry/src/main/ets/pages/Index.ets` 可见删除块里**同时**含 `keepalive` 与 `theme` 两个分支（删「后台保活/通知」时被连带删掉；v1.96 版仍在: `git show 15ec2f4:harmony/entry/src/main/ets/pages/Index.ets` 第 783 行起）。
- 修法: ①新增 `openImeList()`（状态条点击入口）+ 弹框分支 `dialog === 'ime'`：`List` + `ForEach(this.imeItems)` 渲染 `ImeSettings.listAll()` 的**中文 label**（副行包名、当前项标「当前使用 ✓」、剪集项标「剪集 · 点此启用」），点一行调 `switchToIme()`；剪集不在系统列表时顶部红字引导；底部「系统选择器 / 输入法设置」两个按钮；②`switchToIme()` 用 `inputMethod.switchInputMethod(property)` 直切，取不到 / 返回 `false` / `catch` 一律兜底 `this.openImeSettings()` 跳系统「输入法设置」页（限制见 `PIT-047`）；③`refreshIme()` 补 `this.curImeId`、`this.ownRegistered`（弹框标 ✓ 与红字提示要靠它们）；④**恢复** `dialog === 'theme'` 分支（鸿蒙风 / Android 原版单选 + 「当前皮肤」行 + 「键盘皮肤在键盘 ⚙ 里设」的沙箱提示，`PIT-039`）；⑤状态条文案 `(点击切换键盘)` → `(点此选择输入法)`。
- 反例 / 易误判: ①把「弹框只剩关闭按钮」当成主题/渲染问题（真因是 if/else 链缺分支 ⇒ 内容区为空）；②以为系统选择器里的英文是「输入法 label 没写中文」（那是系统选择器的显示口径，`getAllInputMethodsSync()` 给的 `label` 就是中文）；③删一个功能时连带删掉同一条 if/else 链上无关的弹框分支 —— 改 `dialogLayer()` 前后要逐个核对 `this.dialog = '<id>'` 都有对应分支。
- 涉及文件: `harmony/entry/src/main/ets/pages/Index.ets`（本次唯一改动文件，+约 200 行）
- 验证（编译级）: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon` → `BUILD SUCCESSFUL`；编译产物 `harmony/entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts` 内可查到 `openImeList` / `switchToIme` / `皮肤设置` / `当前皮肤` / `切换输入法`，HAP 已重新打包（`entry-default-signed.hap`，21:34）
- 真机装机（2026-10-07，设备 `8HH0226911023008`）: `hdc install -r harmony\entry\build\default\outputs\default\entry-default-signed.hap` → `install bundle successfully`；`bm dump -n com.example.clipboardmerger` 显示 **versionName 1.100 / versionCode 1000012**（与 `AppScope/app.json5` 一致 ⇒ 装的确实是新包，`PIT-029`）；随后 `aa force-stop` + `aa start -a EntryAbility`，`ps -ef` 里 `:inputMethod` 与主进程时间戳均为重启后（`PIT-040`）。装机工具 = SDK 自带 `…\sdk\default\openharmony\toolchains\hdc.exe`（不在 PATH，见 `PIT-036`）
- 追加（2026-10-07 用户反馈「点剪集选项跳系统设置不合理」+ 状态条二合一）: ①切换输入法弹框改**单选按钮**样式（行首 `◉`=当前 / `○`=其它，剪集行标「剪集」），**点当前项只收弹框**（`switchToIme` 开头 `item.id === this.curImeId` 直接 return + notice「已经是当前输入法」），切换失败**不再自动跳**系统「输入法设置」（改为弹框内 notice 提示「请用下面『输入法设置』页」，要不要跳由用户点按钮决定）—— 原来「失败即 `openImeSettings()`」是自作的惊吓；②主界面「共 N 条 / 已选 M 条」提示行与「输入法: …」状态条**合并成一条**（`@Builder topBar()`：左=条数、右=输入法状态、整条可点进输入法列表、底色跟随激活状态），`statusBar`/`imeStatusText` 两个旧符号已删除。
- 追加（2026-10-07，用户要求「把输入法激活状态点击后的动作去掉，并且去掉相应弹框」）: `topBar()` 去掉 `.onClick`、状态条改**只读**（`imeBarText()` 文案去掉「点此切换」）；删除弹框分支 `dialog === 'ime'` 与只为它存在的 `openImeList / switchToIme / findImeProperty / imeListHeight / showImePicker` 五个方法、`curImeId / ownRegistered` 两个状态；App 内切换输入法只剩「更多 → 权限设置 → 输入法设置」（`openImeSettings()` 保留）。副作用：构建日志里 `showOptionalInputMethods` 的 deprecated 告警消失。验证: `BUILD SUCCESSFUL`（HAP 14:17:32）+ 产物 `…/Index.ts`、`modules.abc`、HAP 内 `imeBarText/countText/topBar` 在、`openImeList/switchToIme/imeListHeight/showImePicker` 已消失 + `install bundle successfully`
- 相关: `PIT-047`、`PIT-039`、`ADR-014`（已被 `ADR-015` 取代）、`ISSUE-007`（Android 侧同族“选择器弹不出来”）　- 首次记录: 2026-10-07 ／ 最近复核: 2026-10-07（仅编译通过；真机复验待做）

## ISSUE-009 鸿蒙版：已切到剪集输入法，App 状态条仍显示「未激活」
- 状态: 已修复（代码已改 + 编译通过 + v1.100 已装机；状态条真机复验待做）　- 复发判据: `findstr /n "computeImeActive" harmony\entry\src\main\ets\pages\Index.ets` 必须命中，且 `refreshIme()` 里有 `this.imeActive = this.computeImeActive();`；若全项目**只有** `KeyboardController.ets` 在 `AppStorage.setOrCreate('imeActive', …)` ⇒ 复发（App 侧状态条永远是默认 false）
- 症状: 用户在系统里把当前输入法切成「剪集」后，App 主界面顶部状态条仍是黄条「输入法: 未激活 ⚠️」。
- 根因: App 页的 `imeActive` 是 `@StorageLink('imeActive')`，但**全项目只有键盘进程写过它**（`KeyboardController.ets:51/65`，跑在输入法 Extension 进程）；AppStorage 不跨进程（`PIT-039`）⇒ App 进程读到的永远是默认 `false`，与系统当前输入法无关。`Index.ets` 里从未写过 `this.imeActive`（`git log -S"this.imeActive" -- harmony/entry/src/main/ets/pages/Index.ets` 只命中引入它的 v1.91 `06f6f13`）。
- 修法: App 侧自己问系统（不改键盘进程）：①新增 `computeImeActive()` = `inputMethod.getCurrentInputMethod().name === 'com.example.clipboardmerger'`，异常时退回 `getDefaultInputMethod()`，在 `refreshIme()` 里写入 `this.imeActive`；②新增 `registerImeChange()` 订阅 `inputMethod.getSetting().on('imeChange', cb)`，`aboutToDisappear()` 里 `off`（切输入法后状态条立即变）；③新增 `onPageShow()` 调 `refreshIme()` 兜底（从系统「输入法设置」/其它应用切回来时重判）；④状态条文案改由 `imeStatusText()` 生成，未激活时写出「当前：xxx输入法」让用户知道该切哪个；⑤`@kit.IMEKit` 需额外导入 `InputMethodSubtype`（`inputMethod.InputMethodSubtype` **不存在**，会编译报 `Namespace 'inputMethod' has no exported member`）。
- 反例 / 易误判: ①以为键盘里显示「剪集 · 共 N 条」就说明 App 也该读到同一状态（AppStorage 不跨进程）；②以为切输入法后 App 会自己刷新（不订阅 `imeChange` 就不会）；③把「未激活」当成输入法没注册/没启用（那是 `ImeSettings.ownRegistered()`，弹框里已单独提示）。
- 涉及文件: `harmony/entry/src/main/ets/pages/Index.ets`（约 +60 行）
- 验证: `hvigorw assembleHap …` → `BUILD SUCCESSFUL`；`hdc install -r harmony\entry\build\default\outputs\default\entry-default-signed.hap` → `install bundle successfully`。注意：**手机锁屏时 `aa start` 会被拒**（`10106102 The device screen is locked`），复验前必须先解锁；日志判据 = hilog 里 `A0A11/JianJi` 的 `computeImeActive: current=com.example.clipboardmerger, active=true`
- 相关: `PIT-039`、`ISSUE-008`、`ADR-014`　- 首次记录: 2026-10-07 ／ 最近复核: 2026-10-07（编译 + 装机已过；状态条待复验）

## ISSUE-010 鸿蒙版 IME「删除」键删的是历史记录，编辑框里选中的文字删不掉
- 状态: 已修复（代码已改 + 编译通过 + v1.100 已装机；真机复验待做）　- 复发判据: `findstr /n "deleteSelected" harmony\entry\src\main\ets\InputMethodExtensionAbility\pages\Keyboard.ets harmony\entry\src\main\ets\InputMethodExtensionAbility\model\KeyboardController.ets` 必须两个文件都命中；若键盘里「删除」键的 onClick 又直接调 `this.removeSelected()` ⇒ 复发
- 症状: 在编辑框里选中一段文字后点键盘「删除」**毫无反应**（其实是去删剪贴板历史记录了：列表里没勾选时它会静默删掉最后一条历史）。
- 根因: 移植时把 Android 的语义接错了 —— Android `ClipboardInputMethodService.kt:205-227`（`btnDelete`）删的是**编辑框里选中的文字**（`getSelectedText` + `commitText("")`，拿不到选区再发 `KEYCODE_DEL`）；鸿蒙版 `Keyboard.ets` 的「删除」却接成了 `this.removeSelected()`（删历史记录）。
- 修法: ①`KeyboardController` 新增 `deleteSelected(): boolean`：`deleteForward(n)`（IME Kit 里等价退格/KEYCODE_DEL），`n` = 选区长度（有选中就整段删），无选区时 `1`（退 1 个字符）；没有绑定编辑框返回 false ⇒ 键盘侧 toast「当前没有正在编辑的输入框」；②选区从 `inputMethodEngine.getKeyboardDelegate().on('selectionChange', (oldBegin,oldEnd,newBegin,newEnd) => …)` 记到 `selBegin/selEnd`（IME Kit **没有**「取选中文本」接口，只能这样跟踪，见 `PIT-049`）；③原「删历史记录」能力移到**长按「删除」**（`imeKey(label, color, action, onLongPress?)` 新增可选长按回调）+ toast，并在键盘 ⚙ 设置里写明。
- 反例 / 易误判: ①以为「删除」没反应是面板/焦点问题（其实调用了另一个功能）；②指望 `InputClient` 有 `getSelectedText()`（没有）；③直接把 Android 的 `commitText("")` 照搬（鸿蒙没有这个 API）。
- 涉及文件: `InputMethodExtensionAbility/pages/Keyboard.ets`、`InputMethodExtensionAbility/model/KeyboardController.ets`
- 验证: `hvigorw assembleHap …` → `BUILD SUCCESSFUL`；编译产物 `…/Keyboard.ts`、`…/KeyboardController.ts`、`modules.abc`、`entry-default-signed.hap` 内均含 `deleteSelected` / `selectionChange`；真机复验待做（选中文字点「删除」应整段删除）
- 相关: `ISSUE-008`、`PIT-049`、`PIT-047`　- 首次记录: 2026-10-07 ／ 最近复核: 2026-10-07（编译 + 装机已过）

## ISSUE-011 鸿蒙版：App 里「清空全部 / 左滑删除」不同步到键盘（App → IME 方向缺失）
- 状态: 已修复（编译通过 + v1.100 已装机；真机复验待做）　- 复发判据: `findstr /n "publishHist" harmony\entry\src\main\ets\pages\Index.ets` 命中（清空/左滑删除都走它）+ `findstr /n "applyAppEvent" harmony\entry\src\main\ets\InputMethodExtensionAbility\model\KeyboardController.ets` 命中；若全项目又出现**三参** `EventBus.publish(...)`（不带 src）也算复发
- 症状: 在 App 里点「清空全部」或左滑删除某条，键盘面板里那份历史还留着旧条目；反方向（键盘删 → App 删）却是好的。
- 根因: 同步只做了**单向** —— 键盘侧 `Keyboard.ets` 有 `EventBus.publish('remove'/'clear'/'add'/'snapshot'/'paste')`，App 侧 `pages/Index.ets` 只 `subscribe` 从不 publish；而两侧历史是各自沙箱里的两份数据（`PIT-039`），App 的 `ClipboardStore.clear()/removeAt()` 只改自己那份。
- 修法: ①`EventBus` 事件加 `src`（`SRC_APP`/`SRC_IME`）：同包名两进程，公共事件是**广播**，本进程订阅者也会收到自己发的事件，必须按 `src` 过滤（`PIT-050`）；②App 新增 `publishHist(op,text,ts)`：`clearAll()` → `clear`、左滑删除 → `remove`，并把操作压进 `pendingOps`（上限 50）；③键盘 `KeyboardController.onCreate` 里 `EventBus.subscribe` + `applyAppEvent()`：只处理 `src=SRC_APP`，按 `clear/remove/add/snapshot` 改自己那份 `ClipboardStore`（改完 AppStorage 自动刷新面板，不二次广播）；④键盘进程每次启动发 `hello(src=ime)`，App 收到即补发 `pendingOps` ⇒ 兜住「App 操作时键盘进程不在」的丢事件。
- 已知局限: 公共事件只在两侧进程都活着时送达；键盘在 App 之后才启动靠 `hello` 补发能兜住（前提 App 进程还活着）。彻底方案是持久化待同步队列 + 回执（本次未做，需要时再上）。
- 反例 / 易误判: ①以为改 App 的 `ClipboardStore` 键盘就能看到（两份沙箱数据）；②只加 publish 不加 `src`（App 会收到自己发的 clear 再清一次 ⇒ 回声）；③指望用 `snapshot` 全量合并解决删除（合并只加不减，删掉的条目会被对面推回来）。
- 涉及文件: `model/EventBus.ets`、`pages/Index.ets`、`InputMethodExtensionAbility/model/KeyboardController.ets`、`InputMethodExtensionAbility/pages/Keyboard.ets`（5 处 publish 补 `SRC_IME`）
- 验证: `BUILD SUCCESSFUL`（HAP 14:09:10）+ `install bundle successfully`；产物 `…/Index.ts`、`…/KeyboardController.ts`、`modules.abc`、HAP 内均含 `publishHist` / `applyAppEvent`。真机判据: App 点「清空全部」→ 日志 `publishHist: clear → IME`，键盘进程日志 `appSync: clear ← App`；键盘进程不在时先操作、再拉开键盘，应看到 `hello ← IME: 补发 N 条待同步操作` 紧随 `appSync: ...`
- 追加（2026-10-07，用户要求「App 和 IME 里的剪切项都增加左滑删除」）: App 侧本来就有（`pages/Index.ets` 的 `swipeDelete` builder + 列表项 `.swipeAction({ end: … })`，只是用户没发现 ⇒ 顺手在「关于」弹框加了一行操作提示）；**键盘面板**这次补上：`InputMethodExtensionAbility/pages/Keyboard.ets` 新增 `@Builder swipeDeleteItem(item)`（红底白字「删除」、宽 72）+ 历史列表项 `.swipeAction({ end: … })` + `removeItem(item)`（`EventBus.publish('remove', text, ts, SRC_IME)` → `ClipboardStore.removeAt(idx)` → 从勾选集里剔除 → toast「已删除 1 条（已同步 App）」），⚙ 设置里的操作提示也补了左滑说明。验证: `BUILD SUCCESSFUL`（HAP 14:14:02）+ 产物 `…/Keyboard.ts`、`modules.abc`、HAP 内含 `swipeDeleteItem`/`removeItem` + `install bundle successfully`。⚠️ 真机待复验：IME 面板里 `swipeAction` 是否响应手势（若不灵，退路是行末加「×」按钮，长按删除仍在）。
- 追加（2026-10-07）: 这里的 `onPageShow → pull → 键盘回 snapshot` 把「快照合并」变成高频路径，暴露出合并实现的老 bug（循环 `addText` 会把已存在条目重复插入）⇒ 见 `ISSUE-012`（已改成 `mergeItems` 只补缺的 + `dedupeByText` 自愈）。
- 相关: `PIT-039`、`PIT-050`、`ISSUE-009`、`ISSUE-010`、`ISSUE-012`　- 首次记录: 2026-10-07 ／ 最近复核: 2026-10-07（编译 + 装机已过）

## ISSUE-012 鸿蒙版：App 侧历史出现成片重复（跨进程同步把「快照合并」写成了循环 addText）
- 状态: 已修复（编译通过 + v1.100 已装机，待真机复验）　- 复发判据: `findstr /n "mergeItems" harmony\entry\src\main\ets\pages\Index.ets` 命中（`add` 与 `snapshot` 都走它）；全项目**不应**再出现「`JSON.parse(e.text)` 之后用 `addText` 循环」的合并写法；日志里 `dedupeByText: dropped N` / `mergeItems: +N` 属正常自愈
- 症状: 键盘采集的内容同步到 App 后，App 列表里同一条正文出现多条（反复「切后台再回前台」或开关 App 后越堆越多）。
- 根因: 快照合并一直是「`JSON.parse(e.text)` → 循环 `ClipboardStore.addText(text)`」，而 `addText` **只与最新一条**去重（对齐 Android `addItem` 语义）⇒ 快照里任何「不在 App 列表最前面」的条目都会被重新插一遍。原实现只在键盘面板重建时推一次快照，偶发；`ISSUE-011` 的修复给 App 加了 `onPageShow → publish('pull') → 键盘回 snapshot`，把这条路径变成**高频** ⇒ 重复成片暴露。
- 修法: ①`ClipboardStore` 新增 `dedupeByText()`（按正文去重、保留最新那条）；②新增 `mergeItems(items)`（**只补本地没有的**，开头先自愈一次 `dedupeByText()`，内部 `unshift` 保持最新在前，结束统一 `persist + publish`）；③新增 `parseSnapshot(json)`（新格式 `[{text,timestamp}]`，兼容老 `["text"]`）；④键盘 `publishSnapshot()` 改推对象数组 ⇒ **带上真实时间戳**，App 侧时间显示与 `remove` 的 `text+ts` 精确匹配同时修好；⑤App 的 `add` / `snapshot` 两个分支都改走 `mergeItems`（App 这份是键盘的镜像，同一正文不该出现两条）；⑥键盘侧 `applyAppEvent('snapshot')` 同步改造。
- 反例 / 易误判: ①以为「同步多了」是键盘重复采集（键盘 `addText` 只挡与最新一条重复，属正常语义）；②用 `addText` 承担任何「批量 / 合并」写入（它只是"插入一条"）；③除 `Set` 之外想去重（5000 条上限下 O(n²) 扫不动）。
- 涉及文件: `model/ClipboardStore.ets`、`pages/Index.ets`、`InputMethodExtensionAbility/model/KeyboardController.ets`
- 验证: `BUILD SUCCESSFUL`（HAP 14:36:57）+ `deploy-harmony.bat` 装机 → `install bundle successfully` / 版本校验 `1.100`；产物 `…/ClipboardStore.ts`、`modules.abc`、HAP 内均含 `dedupeByText / mergeItems / parseSnapshot`。真机判据: 开着 App 复制两条不同文字 → 列表各一条；反复切后台回前台 → 条数不增长
- 相关: `ISSUE-011`、`PIT-050`　- 首次记录: 2026-10-07 ／ 最近复核: 2026-10-07（编译 + 装机已过，真机复验待做）
