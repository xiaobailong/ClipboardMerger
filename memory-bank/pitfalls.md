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
- 正确做法: `start "ClipboardMerger Build" cmd /c "build.bat"`，之后**只用 `read_files` 轮询**日志；
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
  实测对照：`gh release delete-asset v1.53 ClipboardMerger-v1.53-54.apk --yes` 报
  `asset ... not found in release v1.53`，但同一条资产（id 583293306，state=uploaded）在 REST 里查得到。
- 反例: 以为“`--clobber` 一定覆盖成功”；把 422 当成“权限 / 标签不存在”。
- 自检: 同一版本**连跑两次** `gh-release.bat`，第二次不应再出现 422。