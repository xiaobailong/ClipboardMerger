# 踩坑记录（pitfalls）

> 上限 12KB（超了照 `WRITING.md` §3 归档）。每条必填：正确做法 / 反例 / 自检（+ 触发条件与现象）。
> 通用坑来自同机同工具链的源仓库 `privi`；本项目事故另注 commit。编号只增不改。
> 标「已归档」的条目：主文件只留一行要点，原文在 `archive/pitfalls-archive.md`。

## PIT-001 长 `powershell -Command`（含正则/管道）被静默拦截 → 退出码 786、无输出
- 触发条件: `powershell -NoProfile -Command "<长串 / 正则 / 管道>"`　现象: 无输出 + 退出码 **786**。
- 正确做法: 逻辑写成 `.ps1`，用 `powershell -NoProfile -ExecutionPolicy Bypass -File <脚本> -参数`；
  只有极短单表达式可留在 `-Command`（如 `build.bat` 里的 `Get-Date -Format yyyyMMdd_HHmmss`、`WriteAllText`）。
- 反例: `powershell -Command "$t -replace '(\+)\d+', ...; [IO.File]::WriteAllText(...)"`
- 自检: 退出码 786，或"没输出但应该有输出" ⇒ 立刻改 `-File`。

## PIT-002 `.ps1` = UTF-8 **带 BOM** + CRLF；`.bat` / `.md` = UTF-8 **无 BOM**（+ CRLF）
- 现象: 无 BOM 的 `.ps1` 被 PowerShell 5.1 按 GBK 读 ⇒ 中文乱码甚至语法错；
  `.bat` 带 BOM ⇒ 首行 `@echo off` 变 garbage。
- 正确做法: 写完核对前 3 字节是否 `EF BB BF`，并统计 CRLF 与 bare LF（几行 PowerShell 即可）。
- 反例: 编辑器"另存为 UTF-8"（多数默认无 BOM）就当合格。
- 自检: `.ps1` 要 `enc=BOM` + `bareLF=0`；`.bat` / `.md` 要 `enc=noBOM` + `bareLF=0`。
- 追加坑: **无 BOM 的 ps1 里不要出现中文字面量 / 中文路径** —— 路径会被 GBK 解码成乱码，
  脚本一声不响、`Get-Content` 返回 **0 行**（看着像"文件是空的"）；改用通配符定位文件。

## PIT-003 嵌套数组被展平 ⇒ 按字符全局替换 — 已归档（2026-09-23）
- 要点: 成对替换用两个独立 `[string]` 参数、单对单次调用；自检: 替换后逐行看 `git diff`。详情: `archive/pitfalls-archive.md`

## PIT-004 替换文本包含查找文本时不能 while/反复 Replace — 已归档（2026-09-23）
- 要点: 只做**单次** `$text.Replace($old,$new)`（否则路径段重复 / 死循环）；自检: grep 重复路径段。详情: `archive/pitfalls-archive.md`

## PIT-005 `echo` 里半角括号写在 `if (...)` 块内 → `)` 提前闭合批处理 — 已归档（2026-09-23）
- 要点: 用 `^(` `^)` / `^&` 转义；自检: 有无 `unexpected at this time`、"只跑一半"。详情: `archive/pitfalls-archive.md`

## PIT-006 `echo` 里的 `>` 要转义；`%ERRORLEVEL%>> file` 相邻会吞内容 — 已归档（2026-09-23）
- 要点: `^>` 转义；退出码先 `set BUILD_EXIT=%ERRORLEVEL%` 再写（或把 `>>` 挪行首）。详情: `archive/pitfalls-archive.md`
- 复发 2026-09-23（`tmp\` 里的测试脚本）: `echo ==== ... => create ... ====` 未转义 `>` ⇒ 仓库根多出 120B 垃圾文件 `create`；临时脚本也要 `^>`。

## PIT-007 `%VAR%` 是解析期展开、`!VAR!` 才是延迟展开（括号块 / 同行 `&` 链必踩）
- 触发条件: 在 `( ... )` 里**先 `set` 再用 `%VAR%`**，或同一行 `&` 链里读刚设的变量 / `ERRORLEVEL`。
- 现象: 取到**空值或旧值**。本项目事故见 `ISSUE-001` 第 1 层（日志路径变空 ⇒ 首行 `[]`）。
- 正确做法: 先设后用就**跳出括号块**（本项目用 `goto :init_log` / `:skip_log`）；
  必须在块内就 `setlocal enabledelayedexpansion` + `!VAR!`；同行 `&` 链用绝对路径；退出码先 `set "RC=%ERRORLEVEL%"`。
- 反例: 块内 `set` + `%VAR%` 混用；`set "FL=path" & "%FL%\x.exe"`；块内读 `%ERRORLEVEL%`
- 自检: 变量 / 退出码判断是否"永远走同一分支"；日志首行是否为空方括号。

## PIT-008 本环境终端抓不到命令输出 ⇒ 重定向到文件再读；**一次只发一条命令链**
- 现象: 提示 `could not be captured through shell integration`；新命令会**掐掉仍在跑的前一条**。
- 正确做法: `cmd > tmp\out.txt 2>&1` 后用 `read_files` 读；多条独立命令串进同一行（`&` / `&&`）；
  长任务用独立窗口（`PIT-009`）。
- 反例: 一条消息里发多条独立命令；依赖终端回显下结论。
- 自检: 关键结果是否落在文件里、能否二次读取复核。

## PIT-009 长构建要放独立窗口，前台跑会被下一条命令掐断
- 触发条件: `build.bat` 这类分钟级任务。
- 现象: 跑到一半被杀，`build\logs\build_<ts>.log` 停在中间。
- 正确做法: `start "剪集 Build" cmd /c "build.bat"`，之后**只用 `read_files` 轮询**日志；
  等一会儿用 `ping -n N 127.0.0.1 > nul`（非交互环境 `timeout` 不可靠）。
- 反例: 前台起构建后又发命令；构建中反复发命令。
- 自检: 日志是否连续；`tasklist /fi "imagename eq java.exe"` 里 Gradle JVM 是否还在。

## PIT-010 `Get-Content` 默认按 GBK(936) 解码 ⇒ 中文被啃成 `?` 或乱码
- 正确做法: `Get-Content -LiteralPath <f> -Raw -Encoding UTF8`；控制台先 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`。
- 反例: `Get-Content build\logs\x.log -Tail 20`
- 自检: 读回来的中文是否正常（拿已知中文行验证）。

## PIT-011 本机 WMI / `jps` / `jcmd` / `Get-Counter` 会**挂死**（无输出、永不返回）
- 正确做法: 内存用 `GlobalMemoryStatusEx`（P/Invoke）或 `Get-Process` + 路径过滤；杀进程 `Stop-Process`；
  "构建是否在跑"用 `tasklist /fi "imagename eq java.exe"`。
- 反例: `Get-CimInstance Win32_OperatingSystem`、`jps -l`、`Get-Counter`
- 自检: 命令是否 1~2 秒内返回（否则立刻停手）。备注: 属"**已规避**"类，不要试图真正修好。

## PIT-012 别用「管道 + PowerShell 逐行追写」给构建做日志 — 已归档（2026-09-23）
- 要点: 用 `call "%~f0" %* 1>> "%_CM_LOGFILE%" 2>&1` + 紧邻 `set _CM_BUILD_RESULT=%ERRORLEVEL%`；
  自检: 日志首行与末尾"日志已保存"都在。详情: `archive/pitfalls-archive.md`
- 补充 2026-09-23: 该"重定向 + 结束后 `type`"方案已废弃（控制台全程空白）→ 改 `tools\tee-log.ps1` 逐行 tee（`ADR-010`）。

## PIT-013 `call` 递归调用自身后，必须**立刻** `set "RC=%ERRORLEVEL%"`
- 现象: 中间的 `echo` / `type` / `timeout` 会改写 `ERRORLEVEL` ⇒ 外层永远拿到成功码 ⇒ **失败却报成功**。
- 正确做法: `call` 回来的下一行 `set _CM_BUILD_RESULT=%ERRORLEVEL%`，最后 `exit /b %_CM_BUILD_RESULT%`
  （`build.bat:17`、`:24`）。
- 反例: `call ... 1>> log 2>&1` 之后隔几行再 `exit /b %ERRORLEVEL%`
- 自检: 故意让构建失败，看外层退出码是否非 0。

## PIT-014 改坏了怎么救：`git checkout -- <路径>` 从 index 还原 — 已归档（2026-09-23）
- 要点: 从 **index** 还原工作区（别用 `git checkout HEAD -- .`）；自检: `git diff --numstat <路径>` 为空。详情: `archive/pitfalls-archive.md`

## PIT-015 诊断产物 / 交接文档不要放 `build\` — 已归档（2026-09-23）
- 要点: 要留存进 `memory-bank\` 或 `docs\HANDOFF-*.md`（`docs/` 需自行 gitignore），纯临时进 `tmp\`。详情: `archive/pitfalls-archive.md`

## PIT-016 同一输出文件反复写入可能只读到旧内容 — 已归档（2026-09-23）
- 要点: 每轮换文件名或先 `del`；判断"还在跑"看 `dir /tw build\logs` + `tasklist`；自检: 内容与刚跑的步骤是否对应。详情: `archive/pitfalls-archive.md`

## PIT-017 检索手段实测：`search_codebase` 常超时、`findstr` 搜中文不可靠 — 已归档（2026-09-23）
- 要点: 优先 `read_files`；批量过滤用 `powershell -File` + `Select-String -Encoding UTF8`；自检: 用"已知一定存在"的词做正控。详情: `archive/pitfalls-archive.md`

## PIT-018 长等待会被提前掐断 ⇒ 轮询必须"先写状态文件、再等"
- 现象: 命令 30~60 秒就被回收，`&` 后面的命令**根本没执行**，状态文件没创建 ⇒ 误判"命令没跑"。
- 正确做法: ①按 1 分钟粒度轮询，**先写状态文件再 `ping -n 400`**；②状态文件写 `tmp\` 或 `build\`；
  ③长任务放独立窗口（`PIT-009`）；④判断"在跑"用 `dir /tw` + `tasklist`。
- 反例: 发一条 `ping -n 600` 指望等 10 分钟；把 `&` 后面的命令当作一定执行。
- 自检: 状态文件 mtime 是否推进；`java.exe` 是否还在。

## PIT-019 临时产物散落在仓库根 ⇒ `git status` 噪声 — 已归档（2026-09-23）
- 要点: 中间文件一律 `tmp\`，收尾 `rmdir /s /q tmp`；自检 `git status --porcelain` 除真实改动外不应有 `??`。详情: `archive/pitfalls-archive.md`

## PIT-020 上一轮构建窗口还停在 `pause` / `timeout 60` 时启动第二轮 ⇒ 并发构建
- 现象: 两个构建抢 `.gradle`/`build`，`versionCode` 连跳，根目录被拷进旧 APK，日志分散难辨认。
- 正确做法: 重跑前 `tasklist /fi "imagename eq java.exe"` + `dir /tw build\logs` 确认真空。
- 反例: 失败后马上原地重跑，再对上一轮的日志/退出码下结论。
- 自检: 新构建 10 秒内出现**新的时间戳日志**；同时只有一个 Gradle JVM 在 assemble。

## PIT-021 【已复现 2026-09-23】日志在 `build\logs\`，而流程第 2 步 `gradle clean` 会删 `build\` — 已归档（2026-09-23）
- 要点: 占用中的日志删不掉 ⇒ gradle clean 静默通过、日志会缺一段；自检: findstr /c:"Unable to delete" build\logs\*.log ｜ 详情: archive/pitfalls-archive.md

## PIT-022 `build.gradle.kts` 里写 `java.text.X` / `java.util.X` 全限定名 ⇒ `Unresolved reference: text / util`
- 原因: 脚本作用域里 `java` 被 Gradle 的 `java`（`JavaPluginExtension`）扩展遮蔽；现象是 `Configure project :app` 段直接
  `e: ...build.gradle.kts:17:22: Unresolved reference: text`（+ `util` 两处），`BUILD FAILED`（2026-09-23 加 `BUILD_TIME` 时踩到）。
- 正确做法: 顶部显式 `import java.text.SimpleDateFormat` / `import java.util.Date` / `import java.util.Locale`，正文用短名。
- 反例: `java.util.Date()`；把报错当成“Kotlin 版本不兼容 / 缺依赖”去查。
- 自检: `Configure project` 段无 `e: file:///...build.gradle.kts`；改完跑一次 `assembleDebug`。

## PIT-023 `cmd /c ""C:\Program Files\...\x.exe" ..."` 吞引号 ⇒ `'C:\Program' is not recognized`
- 触发条件: 批处理里为取版本号写成 `for /f ... in ('cmd /c ""%EXE%" --version | findstr ..."')`；
  现象: 日志出现 `'C:\Program' is not recognized`（`build\logs\build_20260922_231449.log:115`）。
- 正确做法: 直接 `"%EXE%" --version`；要取输出用 usebackq：``for /f "usebackq tokens=3" %%i in (`"%EXE%" --version`) do ...``。
- 反例: `for /f %%i in ('cmd /c ""%EXE%" --version"') do ...`　自检: 日志里不出现 `is not recognized`。

## PIT-024 同一行 `if ... ( ) else ( )` 之后接 `& 命令` ⇒ 后面的命令根本不执行
- 触发条件: 把 `cmd > out 2>&1 & if errorlevel 1 (echo A) else (echo B) & 下一条 > out2` 挤在一行。
- 现象: `out` 写对了，`out2` **文件都不存在**（不是内容错，是压根没跑）。
- 正确做法: `if/else` 单独占行（或用 `goto` 分流）；一行里只留无分支的 `&` 链。
- 自检: 链上每个产物文件是否都生成；缺一个就拆行（别据此以为"命令失败了"）。
## PIT-025 批处理里调另一个 `.bat` 必须 `call`；抽段测试的起点要用「标签行」而不是 `call :label`
- 触发条件: ①`.bat` 里直接写 `other.bat`（不带 `call`）；②用「从某标签切到文件尾」的方式抽子过程去测。
- 现象: ①子批的 `exit /b` 会**顶替父批上下文** ⇒ 父批后续行一行都不执行（静默「跑一半」）；
  ②`IndexOf(':check_gh')` 命中主流程里的 `call :check_gh`，抽出来的是**主流程本体** ⇒ 测试把真实脚本整套跑了一遍（本项目事故见 `ISSUE-006`）。
- 正确做法: ①`call "x.bat"`；②抽取用 `(?m)^:check_gh\s*$` 定位，并断言「首行 = 该标签」「正文不含主流程标志 `[2/6]`」；
  ③测试环境把假 `git` / 假 `gh` 放 PATH 最前，假 git 的 `tag` / `push` 一律失败兜底。
- 反例: 以为「`exit /b 1` 会正常返回父批」；以为「抽段测试只是文本切片，不会执行真流程」。
- 自检: 测试输出里出现主流程标志（`[2/6]` / `Updated tag` / `推送 `）⇒ 主流程被跑，立刻停手查抽取起点。

## PIT-026 `.bat` + `chcp 65001`：头部**中文注释**会被错解析 ⇒ 行错位、注释片段当命令执行
- 触发条件: UTF-8（无 BOM）`.bat` 且前段有中文 / 全角注释；在**新控制台**（起始代码页 936：双击、`start "" /min cmd /c`）运行。
- 现象: 输出顶部冒出 `'EM' is not recognized` / `'…长头部注释块。' is not recognized` 这类垃圾报错；脚本大体还能跑，
  但**被带偏的下一行可能整行失效**（实测 `if … echo …` 整行被吃掉）。同一个脚本从 65001 的控制台跑则完全干净。
- 正确做法: ①**根治 = 脚本开头自我重启一次**：`chcp 65001 > nul` 之后写
  `if defined _CM_XX_RELAUNCH goto :relaunched` → `set "_CM_XX_RELAUNCH=1"` → `cmd /d /s /c ""%~f0" %*"` → `set "_CM_XX_RC=%ERRORLEVEL%"` → `exit /b %_CM_XX_RC%`
  —— 新 cmd 的起始代码页已是 65001，整个文件从第 0 字节起按 UTF-8 解析，中文注释也不再被带偏
  （`build.bat` 一直干净就是这个原因：`tools\tee-log.ps1` 先把控制台设成 UTF-8，子进程一开始就在 65001 下）；
  ②兜底（不重启时）: `REM` / `::` 注释保持 ASCII、中文只放 `echo` 字符串里（实测：ASCII 注释版 0 报错，中文注释版 2~5 条报错）；
  注释里不要出现 `> < & | ^ %`（`REM a > b` 会创建文件、`REM a & b` 会执行 `b`，`PIT-006` 同族）；
  ③把 `chcp 65001` 挪到第 1 行**没用**（实测同样报错）。
- 反例: 以为“有 `chcp 65001` 就没事”；把垃圾报错当成“脚本逻辑坏了 / 命令失败”。
- 自检: 用**新控制台**跑只读模式 `start "" /min cmd /c "gh-release.bat check > tmp\x.out 2>&1"`，
  输出顶部不应出现任何 `is not recognized`；注释行扫描 `rem_bad=0`（临时 ps1：非 ASCII 或 `> < & | ^ %` 计数）。

## PIT-027 `gh release upload --clobber` 会漏删同名资产 ⇒ HTTP 422 `ReleaseAsset.name already exists`
- 触发条件: Release 里已经有同名 APK（尤其是上一次上传中途 TLS 超时 / 中断过），再次 `release upload --clobber`。
- 现象: `HTTP 422: Validation Failed (.../assets?label=&name=xxx.apk)` + `ReleaseAsset.name already exists`；
  此时 `gh release view --json assets` 可能返回**空列表**（`--clobber` 正是靠它找旧资产）—— 但 `gh api .../releases/<id>/assets` 能查到那条已 uploaded 的资产。
- 正确做法: 别信 gh 的资产列表，走 REST：`gh api "repos/<repo>/releases/tags/<tag>" --jq .id` 取 release id →
  `gh api "repos/<repo>/releases/<id>/assets?per_page=100" --jq ".[].id"` 列资产 id →
  逐个 `gh api "repos/<repo>/releases/assets/<id>" --jq .name` 比对文件名，命中即
  `gh api -X DELETE "repos/<repo>/releases/assets/<id>"`，最后再 `release upload --clobber`。
  已落到 `gh-release.bat`（`:drop_same_asset`）。
  实测对照：`gh release delete-asset v1.53 JianJi-v1.53-54.apk --yes` 报
  `asset ... not found in release v1.53`，但同一条资产（id 583293306，state=uploaded）在 REST 里查得到。
- 反例: 以为“`--clobber` 一定覆盖成功”；把 422 当成“权限 / 标签不存在”。
- 自检: 同一版本**连跑两次** `gh-release.bat`，第二次不应再出现 422。

## PIT-028 `showInputMethodPicker()` 静默失败：必须在“窗口已经拿到焦点”之后再调（根因，非华为特有）
- 触发条件: 在 `onCreate`（窗口还没获得焦点）里调 `showInputMethodPicker()`；实测设备 华为 LIO-AN00m / SDK 31，但闸门在 AOSP 里，其它机型同样适用
- 现象: 应用日志显示“已调用”（API 返回 void），但选择器不出现、无异常；系统侧只有一条 `Slog.w("Ignoring showInputMethodPickerFromClient of uid ...")`（`InputMethodManagerService.showInputMethodPickerFromClient()`）
- 正确做法: ①本应用的 Activity 窗口**拿到焦点之后**再延迟几百 ms 调（`onWindowFocusChanged(true)` → `postDelayed(400L)`）：`canShowInputMethodPickerLocked()` 要求 `client == mCurFocusedWindowClient`，它只在 `startInputOrWindowGainedFocus` 成功后更新；②留手动兜底 `Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)`；③窗口不能是不可见的（要有真实、可获焦点的 Activity）；④**自动调用只做一次** —— `InputMethodMenuController.showInputMethodMenu()` 先 `hideInputMethodMenuLocked()` 再新建 dialog（`InputMethodMenuController.java:109`），重复调用 = 关掉再重开（用户看到“一闪而过”），第二次若又被闸门拦下就彻底消失
- 反例: 在 `onCreate` 里直接调（窗口没焦点 ⇒ 被丢弃，还会以为“华为拦截”）；把“调用成功”当“已弹出”
- 自检: `findstr /n "onWindowFocusChanged" app\src\main\java\com\example\clipboardmerger\PickerActivity.kt`（期望 1 处命中）+ 真机日志出现 `showInputMethodPicker() called (attempt=1)` 且选择器可见；`onCreate, showing input method picker` 这种“onCreate 里就调”的日志 ⇒ 复发
- 首次记录: 2026-10-01 ／ 最近复核: 2026-10-01（定案：不是华为特有限制，是 IMMS 的“当前焦点窗口 client”闸门；修法见 `ISSUE-007`）

## PIT-029 真机复验前先确认“装的到底是哪个版本”（拿旧包当新包，白测一轮）
- 触发条件: 改动只在工作区、还没出过包时，直接让用户去真机验证。
- 现象: 用户报“修复无效”，但日志里 `App version: 1.79`，且**新代码独有的日志行**（如 `notificationsEnabled=`）一条都没有 ⇒ 根本没跑新代码。
- 正确做法: 出验证包时同时递增版本号（`gradle :app:incrementVersion` 之后再 `gradle :app:assembleDebug`，**分两次**调用：版本号在配置期读取，同一次调用里改不生效），APK 名 / 关于弹框 / 日志首行都能区分新旧；复验前先在日志里 grep `App version:` 与“新代码独有日志行”。
- 反例: 用同一版本号出包（如 `JianJi-v1.79-80.apk` 与线上包同名同版本），装完无法分辨是不是新包。
- 自检: `findstr /n "App version" <日志>` 看版本 + `findstr /n "notificationsEnabled" <日志>`（v1.80 特有）是否有输出。
- 首次记录: 2026-10-01

## PIT-030 编译报 `Unresolved reference: <layout>/<id>` ⇒ 先查资源文件是不是丢了（不是代码问题）
- 触发条件: 提交/清理只带走了一部分改动（新增的布局没被提交，或被 `git clean` / `checkout` 回退掉），而代码里仍引用 `R.layout.xxx` / `R.id.xxx`。
- 现象: `:app:compileDebugKotlin` FAILED：`Unresolved reference: activity_picker` / `tvPickerMessage` / `btnPickerSwitch` …（本次实测：`activity_picker.xml` + `colors.xml` 里的 `picker_scrim` 一起丢，构建直接编不过）。
- 正确做法: 先核对文件在位 —— `dir /b app\src\main\res\layout`、`git ls-files app/src/main/res/layout`、`git show --stat <commit>`（看那次提交到底带了哪些文件）；缺失就补回来再编译。提交前用 `git status --short` 逐个确认“新增资源 + 被改资源”都进去了。
- 反例: 把 `Unresolved reference: R.layout.xxx` 当“Kotlin 写错了 / 需要 Rebuild / 清 Gradle 缓存”。
- 自检: `git ls-files app/src/main/res/layout | findstr activity_picker` 有输出；`findstr /n "picker_scrim" app\src\main\res\values\colors.xml` 有输出。
- 首次记录: 2026-10-01

## PIT-031 华为/鸿蒙：通知渠道「没有声音」⇒ 永远没有悬浮横幅（importance=HIGH 也没用）
- 触发条件: 自建 `NotificationChannel` 只 `enableVibration(true)`、没 `setSound(...)`（渠道默认无声音）。
- 现象: 通知能进抽屉、`areNotificationsEnabled()=true`、`importance=4`、`shouldVibrate=false`，但**从不出横幅**（v1.82 真机日志原文：`notificationsEnabled=true, bindChannel=bind_app_channel_v2, importance=4, shouldVibrate=false`）。EMUI 把无声音渠道当“静默通知”。
- 正确做法: 渠道必须带声音 —— `setSound(RingtoneManager.getDefaultUri(TYPE_NOTIFICATION), AudioAttributes(USAGE_NOTIFICATION))`；渠道属性不可变 ⇒ **换新 ID**（本项目 `bind_app_channel_v3`，同时删掉 v1/v2）。并且别把“能不能看到提醒”全押在横幅上：更硬的办法是**绕开通知系统**：申请 `SYSTEM_ALERT_WINDOW`（显示在其他应用上层）后自绘悬浮气泡 + 直接调 `Vibrator`（见 `PIT-032`）。
- 反例: 只调 `IMPORTANCE_HIGH` + 振动就以为有横幅；对同一个渠道 ID 反复 `delete` + 重建（v1.79 实测无效）。
- 自检: 启动日志 `hasSound=${channel.sound != null}`（期望 true）+ 真机亮屏/锁屏各验一次横幅。
- 首次记录: 2026-10-01

## PIT-032 静音 / 振动 / 免打扰下通知横幅整条消失 ⇒ 提醒必须绕开通知系统（自绘悬浮窗 + 直接振动）
- 触发条件: 把“提醒用户”设计成通知横幅（哪怕 `IMPORTANCE_HIGH` + 有声音 + 振动 + 全屏 Intent），而设备处于**静音 / 振动 / 免打扰**（华为/鸿蒙实测）。
- 现象: 通知只进抽屉、甚至完全不显示（`notificationsEnabled=true`、`importance=4`、`hasSound=true` 都没用）⇒ 用户永远看不到提醒。
- 正确做法: ①申请 `SYSTEM_ALERT_WINDOW`（显示在其他应用上层），用 `WindowManager` + `TYPE_APPLICATION_OVERLAY` 画自绘气泡，带 `FLAG_NOT_FOCUSABLE`（不抢焦点、不影响用户在别的 App 里打字）；②提醒时直接 `Vibrator` 振一下（`VibrationEffect.createOneShot(300L, DEFAULT_AMPLITUDE)`，不经过通知系统）；③通知降级为“没有悬浮权限时”的兜底，并在日志里写明原因。
- 反例: 继续在渠道重要性 / 声音 / 全屏 Intent 上调参（这些都在通知系统里，模式一开全废）；拿到悬浮权限只把它当“后台启动豁免”而不真的用它显示内容。
- 自检: 手机切静音 + 开免打扰 → 进绑定 App → 应看到顶部悬浮气泡 + 一次振动（日志 `BindAppBubble: shown` + `vibrated reminder feedback`）。
- 首次记录: 2026-10-01

## PIT-033 华为「一键清理」杀掉后不自拉起：开了自启动也不等于自动复活
- 触发条件: 华为/鸿蒙点「一键清理 / 手机加速」把后台清掉，本应用（含前台服务）一起被杀；用户已在系统里开了「自启动」。
- 现象: 后台监控静默消失（日志停在被杀那一刻，之后再没有 `ClipboardService.onCreate`），绑定提醒再也不触发；用户以为“开了自启动就会自己回来”。
- 正确做法（App 侧只能做到这些，按可靠性排序）:
  ①**拿输入法当锚点**：`ClipboardInputMethodService.onCreate()` 里 `KeepAlive.startServiceIfEnabled()` —— 剪集本身是输入法，用户点任何输入框系统都会拉起输入法服务，这是最可靠的复活点；
  ②**开机 / 应用更新**：`BootReceiver` 监听 `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`（需 `RECEIVE_BOOT_COMPLETED`）→ `startForegroundService`；
  ③**从最近任务划掉**：`Service.onTaskRemoved()` 里用 `AlarmManager` + `PendingIntent.getForegroundService` 安排 1s 后自拉起（不要在回调里直接 startService，会被后台启动限制拦掉）；
  ④**忽略电池优化**：`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`；Android 12+ 这同时放开“后台启动前台服务”的限制；
  ⑤系统侧引导（App 里给用户看）：应用启动管理 → 手动管理（自启动 / 关联启动 / 后台活动）+ 最近任务卡片**下拉加锁**。
- 反例: 以为“自启动 = 一定会自动回来”；以为 `START_STICKY` 能救一切（被 force-stop 或整进程被杀后不会回调）；在 `onTaskRemoved` 里直接 `startService`。
- 自检: 一键清理后点一个输入框 → 日志应出现 `KeepAlive: background service start requested`，随后 `ClipboardService.onCreate` 与 `reminder gate reset` 再次出现。
- 首次记录: 2026-10-01

## PIT-034 鸿蒙 7「卓易通」里装的 APK 永远成不了系统输入法（只有原生 HAP 有解）
- 触发条件: HarmonyOS NEXT（用户机 = 鸿蒙 7）用卓易通（安卓兼容容器）安装本应用，去系统输入法列表里找「剪集」。
- 现象: 能装能启动，但**不会被识别成输入法**（鸿蒙的输入法列表里没有它）；`BIND_INPUT_METHOD` + `@xml/input_method_config` 只在容器内部的安卓里生效。
- 正确做法: 鸿蒙上必须写**原生输入法** —— `InputMethodExtensionAbility` + `module.json5` 里 `"type": "inputMethod"`、`metadata: { name: "ohos.extension.input_method", resource: "$profile:input_method_config" }`；剪贴板历史用 `@kit.BasicServicesKit` 的 pasteboard 采集（API 12+ 需 `ohos.permission.READ_PASTEBOARD`）。本仓库实现见 `harmony/`（`ADR-013`）。
- 反例: 改 `AndroidManifest.xml`（权限 / `input_method_config.xml` / targetSdk）期待容器放行；把 `showInputMethodPicker()` 时序或透明 Activity 当根因（那是 `ISSUE-007` 的安卓侧问题，与容器无关）。
- 自检: 鸿蒙「设置 → 系统和更新 → 输入法」里能看到「剪集输入法」= 原生 HAP 生效；如果只有卓易通里能起来 ⇒ 必然看不到。
- 相关: `ADR-013`、`ISSUE-007`（安卓侧同类症状、根因不同）　首次记录: 2026-10-05

## PIT-035 `fetch_web_content` 抓长文件会中间截断 ⇒ 单请求 + 找官方小文件/`.d.ts`
- 触发条件: 抓 20KB 以上的源码或文档（例：`js-apis-inputmethodengine.md` 230KB、样例 `KeyboardController.ets` 30KB）。
- 现象: 返回「开头 + 结尾」、**中间被吞**（提示 `[truncated N chars]`），被吞的往往正是关键片段（如 `createPanel` 的调用）；一次发多个 URL 时每个拿到的更少。
- 正确做法: ①一次只发 1 个 URL；②优先抓**按类拆分的官方文档**（`js-apis-inputmethod-panel.md` 只有 2KB，`PanelInfo/PanelType/PanelFlag` 定义全在里面）或先抓 `Readme-CN.md` 索引找小文件；③要 SDK 声明就去抓 `openharmony/interface_sdk-js` 的 `.d.ts`；④Bing/duckduckgo 在中文技术词上常返回无关结果（甚至词典），别依赖。
- 反例: 拿截断后的片段猜 API（`inputMethodEngine.FLAG_DEFAULT` 这类不存在的常量就是这么臆造出来的）；反复重抓同一个大文件。
- 自检: 关键定义是否来自**完整文件**（size 小、或首尾连续、无 `[truncated]` 提示）。
- 首次记录: 2026-10-05


## PIT-036 鸿蒙本机构建：用「命令行工具」即可（不必装 DevEco）；API 26 的 IME 接口与旧文档有 4 处不一致
- 触发条件: 想在本机编译/打包鸿蒙工程，但没有（或不装）DevEco Studio。
- 现象: hvigor + HarmonyOS SDK 只随 DevEco / 命令行工具分发；公共 npm 与华为云镜像上 `@ohos/hvigor` **全部 404**（实测 `registry.npmjs.org`、`registry.npmmirror.com`、`repo.huaweicloud.com/repository/npm`）⇒ 光靠 npm 装不出构建环境。
- 正确做法: ①装华为 **command-line-tools**（本机 `D:\Tools\DevTools\hmos\command-line-tools`，v26.0.0.851：`bin\hvigorw.bat` + `hvigor\` + `ohpm` + `tool\node` + `sdk\default\{openharmony,hms}`）；②`build-harmony.bat` 会自动识别它（可用 `HOS_CLT` 覆盖），也可 `set "DEVECO_HOME=<工具链目录>"`；③`bin\hvigorw.bat` 自己设 `DEVECO_NODE_HOME` / `DEVECO_SDK_HOME`，**不用**手工指 SDK；④签名工具/默认证书在 `sdk\default\openharmony\toolchains\lib\`（`hap-sign-tool.jar`、`OpenHarmony.p12`、`Unsgned*ProfileTemplate.json`），装机工具 `toolchains\hdc.exe`。
- API 26 实测与旧文档（API 12 前后）不一致的 4 处（一律以本地 `sdk\...\ets\api\*.d.ts` 为准）:
  1. `compatibleSdkVersion`/`targetSdkVersion` 写 **`"26.0.0"`**（平台版本号）。写 `"26.0.0(26)"` 或 `"5.0.0(12)"` 直接失败：`Error Code: 00308018 api version parameter is illegal! Expected format: <major>[.<minor>][.<patch>]`。
  2. `createPanel` **不在** `inputMethodEngine` 命名空间上，而是 `inputMethodEngine.getInputMethodAbility().createPanel(ctx, info)`，**返回 `Promise<Panel>`**（先 await/.then 拿到 panel 再 `setUiContent`；直接 `this.panel.setUiContent()` 会报 `Object is possibly 'undefined'`）。
  3. `InputMethodAbility.on('inputStop', cb)` 的回调**无参数**（只有 `on('inputStart')` 是 `(kbController, inputClient)`）。
  4. `PanelFlag` 有两套：`@ohos.inputMethod.Panel` 里是 `FLAG_FIXED`，而 `InputMethodAbility.createPanel` 要的 `inputMethodEngine.PanelFlag` 是 **`FLG_FIXED`**（`PanelInfo.flag` 可省略，默认固定态）⇒ 统一用 `inputMethodEngine.PanelInfo/PanelType` 最省事。附：`abilityAccessCtrl.PermissionRequestResult` 经 `@kit.AbilityKit` 导不出来，改成 `const r = await at.requestPermissionsFromUser(...)` 让编译器推断。
- 反例: 照网页文档/官方样例（API 12 时代）逐字抄 —— 上面 4 处全踩；以为"没有 DevEco 就没法本机构建"；把 `READ_PASTEBOARD` 的 `ArkTS:WARN To use this API, you need to apply for the permissions` 当错误（声明过权限就是 WARN，不是失败）。
- 自检: `build-harmony.bat` 走到 `BUILD SUCCESSFUL` 且 `build\harmony\*.hap` 存在；编译 0 ERROR（仅允许 READ_PASTEBOARD 的 WARN）。
- 相关: `ADR-013`、`PIT-035`　首次记录: 2026-10-05
- 追加(2026-10-07): 同一条链上的两个坑见 `PIT-037`（DevEco 自动签名后 product 缺 `"signingConfig": "default"` ⇒ 出 unsigned 包；装机报 `install already exist`）、`PIT-038`（ArkUI 保留成员名撞名）。

## PIT-039 IME Extension 跑在**独立沙箱**：与 App 的 preferences / 文件**都不互通**（"App 设置 → 键盘生效"全废）
- 触发条件: 把"键盘要用的配置"（切换目标、键盘高度、皮肤、日志开关）存在 App 侧 `preferences` 里，指望输入法进程能读到。
- 现象: ①App 里设「切换目标=小艺」，键盘按「切换」却切到**百度**（键盘侧读不到 ⇒ `effectiveTarget()` 回退"列表第一个非本应用输入法"）；②App 把高度改成 0.55，键盘始终 0.30（读到自己沙箱里的默认值）；③键盘侧写回的报告/日志，App 侧**永远读不到**（日志文件里连键盘进程的行都没有）。
- 正确做法: ①**凡是"键盘要用的设置"一律放进键盘面板内的 ⚙ 设置**（键盘进程自己读写自己的 preferences，见键盘 `ImeSettings.getTarget/setTarget/heightRate/setHeightRate`）；②跨进程通信只能走**公共事件**（`commonEventManager.publish/createSubscriberSync`，本项目 `model/EventBus.ets`）；DataShare 在本版本不可用（见 `PIT-046`）；③键盘进程要落日志必须在 `KeyboardController.onCreate` 里显式 `Logger.init(扩展上下文)`，否则只进 hilog。
- 反例: 在 App 侧加"沙箱说明"文案就完事（功能照样不生效）；把配置同时写两处却不做同步（两边各读各的，越用越乱）。
- 自检: 键盘内 ⚙ 里设「切换目标=小艺」→ 按「切换」应 toast「切到 小艺输入法 → 成功」；App 里改高度不应影响键盘（反之亦然），两侧的日志/历史各自独立。
- 首次记录: 2026-10-07

## PIT-040 改完输入法代码必须 `aa force-stop`：`kill -9` 杀不掉，且老进程会一直跑旧代码
- 触发条件: 改完 IME（键盘面板/控制器）代码、装机后直接测。
- 现象: 改了半天"没反应"—— toast 不出、报告不显示、高度不变。`ps -ef | grep <bundle>` 显示 `…:inputMethod` 进程的启动时间**早于**本次安装时间 ⇒ 它跑的是旧代码。
- 正确做法: 装机后 `hdc shell aa force-stop com.example.clipboardmerger`（返回 `force stop process successfully.`）再测；`kill -9 <pid>` 会被系统拒绝（`Operation not permitted`）。排查顺序：先 `ps -ef | grep <bundle>` 对比进程启动时间 vs 安装时间。
- 反例: 反复改代码/重装，却不重启输入法进程；用 `kill` 当重启手段。
- 自检: 重装后 ps 里 `:inputMethod` 的启动时间应晚于 HAP 构建时间。
- 首次记录: 2026-10-07

## PIT-041 面板（键盘）尺寸：`resize` 必须在 `setUiContent` **之后**调；尺寸最终由系统按内容算
- 触发条件: 想改键盘面板高度（`PanelType.SOFT_KEYBOARD`）。
- 现象: 只在 `createPanel().then()` 里 `resize` ⇒ 高度毫无变化；`adjustPanelRect` 是另一条路（`@ohos.inputMethodEngine.d.ts` 的 `adjustPanelRect(flag, rect)`）。
- 正确做法: ①`panel.setUiContent(...).then(() => this.resizePanel(panel))`（**设置内容之后再 resize**）；②`inputStart` / `keyboardShow` 各再 resize 一次；③页面根节点用算出来的高度 `.height(kbH)`（`kbH = px2vp(屏高 × 比例)`）——面板尺寸跟随内容；④比例从**键盘自己的** preferences 读（见 `PIT-039`）。
- 反例: 只改一个地方就以为生效；用 `px`/`vp` 混着填（面板 `resize` 用 px，页面高度用 vp）。
- 自检: 键盘内 ⚙ →「高度+」两次，键盘当场变高；日志有 `panel.resize ok: <w>x<h> (rate=…)`。
- 首次记录: 2026-10-07

## PIT-042 面板内的设置面板会被裁掉 ⇒ 用 `Scroll`，不要靠"临时改面板高度"
- 触发条件: 在键盘面板里塞设置项（目标列表 + 高度 + 皮肤 + 日志）。
- 现象: 面板高度只有屏高 0.30，第三组设置（皮肤）根本看不到；"点开设置时把面板撑到 0.6"虽能看到，但用户明确要求别动高度。
- 正确做法: 设置区套 `Scroll() { Column() { … } }.layoutWeight(1).scrollBar(BarState.Auto)`，并让设置区与历史列表**互斥**（`if (showSettings) {} else if (空) {} else { 列表 }`）。
- 反例: 靠调 `resize` 解决可滚动问题（治标且违反用户预期）。
- 自检: 键盘内点 ⚙ 能滚到最下面的「键盘皮肤」并切换生效。
- 首次记录: 2026-10-07

## PIT-043 ArkTS 编译期的三个"听起来不像编译错误"的坑
- 触发条件: ①想按条件渲染不同组件；②往 `bindMenu([...])` 里插菜单项；③给 `@kit` 模块补 import。
- 现象: ①`'… ? Text('x').fontSize(13) : this.filledButton(…)' does not meet UI component syntax`（**三元表达式不能当组件**）；②数组里出现空对象 ⇒ `No overload matches this call` + `Property assignment expected`（插项时把上一项的 `{` 也复制了）；③`Duplicate identifier 'Notify'`（文件里已有同名 import）。
- 正确做法: ①用 `if (cond) { … } else { … }`；②插菜单项时**先看上一行是否已有 `{`**，成对增删；③补 import 前先搜同文件是否已导入。
- 反例: 把报错当"环境问题"重装 SDK；连续两次犯同一个 `{` 重复的错（本项目 3 次）。
- 自检: `COMPILE RESULT:FAIL {ERROR:n}` 里 ERROR 为 0；`BUILD SUCCESSFUL` 且日志出现 `install bundle successfully`。
- 首次记录: 2026-10-07

## PIT-044 `deploy.bat` 的 install 阶段会被"新的前台命令"打断（日志出现 `^C`）⇒ 必须确认装机成功
- 触发条件: 构建脚本跑在后台（`start /b`）时，仍在同一终端里发新命令/读取。
- 现象: 构建日志停在 `===INSTALL===` 后跟一个 `^C`，`install bundle successfully` 没出现 —— 以为装上了，其实没装。
- 正确做法: 每次构建后 `findstr "BUILD SUCCESSFUL" / "install bundle successfully" / "===DONE"` 三件套确认；缺 install 就手动 `hdc install -r harmony\entry\build\default\outputs\default\entry-default-signed.hap`（用 `-r` 保留数据，别 `uninstall` 否则 GitHub token 等配置全丢）。
- 反例: 只看 `BUILD SUCCESSFUL` 就当装机完成。
- 自检: 日志末尾有 `===DONE`，且 `inst*.txt` 里有 `install bundle successfully`。
- 首次记录: 2026-10-07
