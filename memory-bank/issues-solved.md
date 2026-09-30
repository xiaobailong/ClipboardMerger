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
- 复发判据（静态，5 秒）: `findstr /n "onWindowFocusChanged" app\src\main\java\com\example\clipboardmerger\PickerActivity.kt`（期望 1 处命中）+ `findstr /n "bind_app_channel_v2" app\src\main\java\com\example\clipboardmerger\ClipboardService.kt`（期望命中）；出现“onCreate 里就直接 showInputMethodPicker()”或渠道 ID 又变回 `bind_app_channel` ⇒ 复发。真机判据: 绑定抖音 → 打开抖音 → ①顶部出现提醒（横幅或提醒页）②点按钮后弹出选择器（日志出现 `showInputMethodPicker() called (attempt=1)`）
- 根因（AOSP 源码证据）: `InputMethodManagerService.canShowInputMethodPickerLocked()`（Android 12 / LineageOS 19.1 `InputMethodManagerService.java:3680-3693`）只在 ①`client == mCurFocusedWindowClient`（调用方就是“当前焦点窗口”）②或调用方 uid 拥有当前输入法 时才返回 true；否则 `showInputMethodPickerFromClient()`（同文件 `3696-3714`）只打一句 `Slog.w("Ignoring showInputMethodPickerFromClient of uid ...")` 后 return —— **应用侧无异常、无返回值**。而 `mCurFocusedWindowClient` 只在 `startInputOrWindowGainedFocus` 成功后赋值（同文件 `3503-3505`），也就是“窗口拿到焦点”之后。
  - 落在本项目: v1.78 / v1.79 都在 `PickerActivity.onCreate` 里（启动后约 8ms）就调 `showInputMethodPicker()`，此时窗口还没拿到焦点 ⇒ 调用必然被丢弃。不是华为独有的拦截（PIT-028 的旧结论按本条修正）。
- 证据（真机日志 `jianji_log_2026-10-01.txt`，v1.79 实跑；交接文档旧结论“未见 v1.79 运行记录”已过期）: `00:52:42.841 bind app notification sent for [抖音]` → 用户点通知 `00:53:01.517 PickerActivity: onCreate` → `.525 showInputMethodPicker()` 调用 → `00:53:03.109 destroyed`（1.5s 延迟到点），全程无异常、选择器不出现 ⇒ 与“被 IMMS 静默忽略”完全吻合。
- 修法（v1.80）: ①`PickerActivity` 改成**可见**的半透明卡片页（`Theme.JianJi.Picker` + `activity_picker.xml`）：在 `onWindowFocusChanged(true)` 之后延迟 400ms 才调 `showInputMethodPicker()`，再等 1.5s 若窗口焦点仍在（说明被忽略）补一次；附「弹出输入法选择器 / 打开系统输入法设置 / 关闭」三个兜底按钮；选择器弹出会让本页失焦，焦点回来即 `finish()`（回到抖音），另加 60s 兜底自动关闭。
  ②通知换新渠道 ID `bind_app_channel_v2`（HIGH + 振动 + `setShowBadge(true)`）并删掉老渠道 `bind_app_channel`（渠道属性创建后不可变，对同一 ID `delete+重建` 无效）；通知加 `setFullScreenIntent(intent, true)`（设备在用→悬浮横幅，息屏/锁屏→直接拉起提醒页）+ `USE_FULL_SCREEN_INTENT` 权限；③服务启动时打一行诊断 `notificationsEnabled / bindChannel / importance / shouldVibrate`（下次真机直接看这行）。
- 历史症状链（v1.75 → v1.79 版本演进，已归档）: v1.75 后台 `showInputMethodPicker()` 被吞 → v1.77 通知跳 `ACTION_INPUT_METHOD_SETTINGS`（打开的是设置页不是选择器）→ v1.78/v1.79 透明 `PickerActivity` + `deleteNotificationChannel`；原文见 `archive/issues-solved-archive.md`
- 涉及文件: `ClipboardService.kt`、`PickerActivity.kt`、`activity_picker.xml`、`themes.xml`、`colors.xml`、`strings.xml`、`AndroidManifest.xml`、`MainActivity.kt`
- 反例 / 易误判: ①把 `showInputMethodPicker()`“调用成功”当“已弹出”（它是 void，被忽略时零反馈）②把根因写成“华为拦截透明 Activity / finish 太快”（v1.78/v1.79 的旧结论）③以为 `deleteNotificationChannel` + 重建能改旧渠道属性。兜底（华为实在不行）: `Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)`。
- 相关: `PIT-028`、`ADR-012`、`handover-bind-app.md`　首次记录: 2026-10-01 ／ 最近复核: 2026-10-01（v1.80：重写 PickerActivity + 换渠道 ID + 全屏 Intent，`gradle :app:assembleDebug` 通过，待真机复验）