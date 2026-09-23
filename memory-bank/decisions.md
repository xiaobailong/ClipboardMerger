# 技术决策（decisions / ADR）

> 上限 12KB（超了照 `WRITING.md` §3 归档；已废弃的移入 `archive/decisions-archive.md`）。
> 每条：背景 / 决策 / 理由 / 备选与为何不选 / 影响。编号只增不改。模板见 `WRITING.md` §1。

## ADR-001 知识库制度：`memory-bank` 按需读取 + 体积阈值 + 归档（控 token） — 已归档（2026-09-23）
- 要点: 只读索引 → 只读命中的那 1 个文件 → 主文件超限先归档；规则常驻 `.clinerules`、写条目看 `WRITING.md`；收尾清 `tmp\`；
  自检 bytes/编码/交叉引用无悬空。详情: `archive/decisions-archive.md`

## ADR-002 Cline 临时产物一律写进仓库根 `tmp\`
- 日期: 2026-09-23 | 状态: 已采纳
- 决策: 中间文件写 `tmp\`（单层，不建子目录）；`.gitignore` 忽略 `/tmp/`；
  `clean.bat` 与 `build.bat clean` 都整目录删除 `tmp\`。
- 理由: `git status` 只剩真实改动；清理一条命令；不会误删业务文件。
- 备选与为何不选: 系统 `%TEMP%`（跨会话找不回证据）；`build\`（会被 clean 清掉、易被当构建产物）；
  每任务建子目录（过度设计）。
- 影响 / 约束: 例外只有四类（`build\logs\`、`memory-bank\`、`docs\HANDOFF-*.md`、长期脚本）；
  收尾回复要说明 `tmp\` 是否已清空。

## ADR-003 构建日志用「`call` 递归 + 文件重定向」 — 已废弃（2026-09-23，被 `ADR-010` 取代）
- 要点: 当年为避开「管道 + PowerShell 追写」丢内容（`PIT-012`）改用重定向 + 结束后 `type` 回显；
  代价是控制台要等构建跑完才刷（`ADR-010` 已换成 tee 包装器）。`_CM_LOG_ACTIVE` 递归判别仍有效。
  详情: `archive/decisions-archive.md`

## ADR-004 自测不触碰发布：校验用 Gradle 直跑，发布才用 `build.bat`
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: `build.bat` 默认流程含 `git commit` + `push` + 打 tag + `gh release create`（不可逆）。
- 决策: 校验用 `"D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" :app:compileDebugKotlin --no-daemon --console=plain`
  （最快）或 `assembleDebug`（含资源打包）；需要 `JAVA_HOME` / `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `PATH`
  指向 `D:\Tools\DevTools\...`（`gradle.properties` 已设 `org.gradle.java.home`）。
  发布只在用户明确要求时跑 `build.bat` / `build.bat release`，且先 `git status` 确认干净。
- 理由: 直跑结论一样干净（编译不看 `build.bat` 的发布逻辑），且不动 `version.properties`、不碰远端。
- 备选与为何不选: 新增 `build.bat check` 子命令（要改正在频繁变动的 `build.bat`）；
  跑完 `build.bat` 再手动回退（远端 tag / Release 已经动过）。
- 影响 / 约束: 校验产物版本号 = 当前 `version.properties`（`incrementVersion` 是独立任务，不会被 `assembleDebug` 触发）。

## ADR-005 版本号单一真源 `version.properties`，APK 命名带版本号
- 日期: 2026-09-23 | 状态: 已采纳
- 决策: `version.properties`（`versionCode` / `versionName`）为唯一真源，`app/build.gradle.kts` 读取；
  `incrementVersion` 任务负责递增；APK 固定命名 `ClipboardMerger-v<versionName>-<versionCode>.apk`；
  `layout.buildDirectory = rootProject/build` ⇒ 产物在仓库根 `build\outputs\apk\debug\`，
  `build.bat` 再复制一份到仓库根（`*.apk` gitignored，分发走 GitHub Release）。
- 理由: 用 Gradle 改属性文件比批处理文本重写可靠；文件名带版本号方便真机区分安装包。
- 备选与为何不选: 版本号写死在 gradle 文件（每次改都产生代码 diff 噪声）；
  用 git tag / commit 数当版本（与应用内标题栏不好对齐）。
- 影响 / 约束: 别手工改该文件；构建失败也会消耗 `versionCode`（`ISSUE-002`）；
  改 APK 命名要同步 `build.bat` 里 `dir /s /b build\outputs\apk\debug\*.apk` 的查找。

## ADR-006 发布用 `gh` CLI；`build.bat` 与 `build.bat release` 的差异保留
- 日期: 2026-09-23 | 状态: 已采纳
- 决策: `build.bat`（双击/无参）= 递增 → `gradle clean` → `assembleDebug` → 复制 APK → `git commit`/`push` →
  打 tag `vX.XX` → `gh release create`（失败硬退出）；"版本号未变更"时改为检测推送状态并 `git tag -f` 重打。
  `build.bat release` = 先 `git diff --quiet` 要求工作区干净，再走 6 步（`pause` 便于看错误）。
- 理由: 两种入口对应两种心态（随手发版 / 正式发版），差异已固化，不要"顺手统一"。
- 备选与为何不选: Gradle 发布插件（新增依赖与认证配置）；只保留一条路径（牺牲易用或严谨）。
- 影响 / 约束: 改发布流程前确认工作区干净 + `gh auth status` 正常；`gh` 缺失时脚本直接退出（不是跳过）；
  失败分支的 `pause` 会让窗口挂住，重跑前按 `PIT-020` 确认真空。

## ADR-007 Token 策略：仓库侧（`.clineignore` + 精简 `.clinerules` + 检索式知识库）+ 客户端侧（Auto-Compact / `/smol` / `/newtask`） — 已归档（2026-09-23）
- 要点: 仓库侧 = `.clineignore` 挡构建产物（**故意保留 `build/logs/`**）+ `.clinerules` 只留硬约束 + 知识库检索式读取 + 主文件限体积；
  客户端侧 = 开 Auto-Compact、收尾 `/smol`、换任务 `/newtask`。详情: `archive/decisions-archive.md`

## ADR-008 应用内“更多”入口与构建信息：BuildConfig 注入；日志开关收口到 `Logger` — 已归档（2026-09-23）
- 要点: 工具栏单按钮 → `PopupMenu`（`menu/settings_menu.xml`：日志 / 关于）；构建信息 `BUILD_TIME` / `GIT_COMMIT`
  配置期注入 `BuildConfig`（`app/build.gradle.kts`，需 `buildConfig = true`）；日志开关唯一入口 `Logger.setEnabled()`（内存 + prefs）。
  详情: `archive/decisions-archive.md`

## ADR-009 gh 发布逻辑集中成 `:check_gh` / `:gh_release` 子过程，并做成幂等
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: `:build` 与 `:release` 各有两份 `gh release create`（共 4 处）+ 硬编码仓库全名；`if ... else (...)` 里还带裸括号，
  直接导致整块解析失败、Release 从来没发出去（`ISSUE-004`）。
- 决策: ①`set "GH_REPO=xiaobailong/ClipboardMerger"` 单一来源；②`:check_gh` = “路径存在 + `--version` + `auth status`”，
  失败 `exit /b 1`；③`:gh_release` = `release view` 判存在 → 不存在走 `release create`，存在走 `release edit` +
  `release upload --clobber`，最后打印 Release URL，成功 `exit /b 0`；④调用处一律 `call :gh_release` + `if errorlevel 1`
  **硬失败**（不再“警告后继续”，避免“没发出去却报成功”）；⑤标签：本地 `git tag -f -a`，远端先普通推送，失败自动回落 `-f` 并打警告。
- 理由: 同一版本重跑不会卡在 `already exists` / tag 冲突；日志里直接给出 Release URL（可验证）；一处改动两处生效。
- 备选与为何不选: 用 `gh api` + JSON 判断存在（多一层解析）；保留“已存在只警告”（用户拿不到新 APK 却看到成功）；
  引入第三方发布插件（新增依赖与凭据配置）。
- 影响 / 约束: 改 gh 行为只改这两个子过程，改完必须跑 `ISSUE-004` 的复发判据 + 抽段测试（禁跑 `build.bat`，见 `ADR-004`）；
  `--clobber` 会先删同名资产再上传，上传失败原资产会丢（可接受）；子过程必须留在 `exit /b 0` 之后，别被主流程顺序执行到。
- 追加（2026-09-23）: 所有推送统一走 `:git_push <ref> [force]`（3 次重试 + 3 秒间隔 + 失败指引，覆盖 main / tag / tag force，
  见 `ISSUE-005`）；`git push` 只允许出现在这个子过程里，调用方只 `call :git_push`。

## ADR-010 构建日志改「tee 包装器」：逐行先落盘、再回显（取代 ADR-003）
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: `ADR-003` 的「重定向 + 结束后 `type`」让控制台**全程空白**，构建几十秒看不到进度/报错；需求 = 每条日志先写文件、再同步展示。
- 决策: 新增 `tools\tee-log.ps1`（UTF-8 BOM + CRLF）：`StreamWriter(AutoFlush=true)` 逐行写日志 → `[Console]::Out.WriteLine` 逐行回显；
  `build.bat :init_log` 改为 `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\tee-log.ps1" -Log "%_CM_LOGFILE%"`；
  被包装的 .bat 路径/参数经环境变量 `_CM_SELF` / `_CM_ARGS` 传入（避开 cmd 引号地狱），子进程用
  `cmd /d /s /c ""<bat>" <args> 2>&1"` 只留一个输出流（顺序不乱）；日志仍 UTF-8 BOM；退出码经 PS `exit` 原样回传
  （`set _CM_BUILD_RESULT=%ERRORLEVEL%` 不变）；保留 `_CM_LOG_ACTIVE` 递归判别；缺 `tools\tee-log.ps1` 时 `goto :log_legacy` 降级回老路径。
- 理由: 与 `PIT-012` 的失败模式不同 —— 不再用管道喂 `-Command`（改 `-File` + env 传值），无 cmd 解析期展开问题；
  逐行 `AutoFlush` + 单流读取 ⇒ 文件先、控制台后，顺序稳定。
- 备选与为何不选: 回到「管道 + PowerShell 追写」（`PIT-012` 已证丢内容）；`Get-Content -Wait` 跟随日志（要并行 tail 进程，结束时机与退出码难把握）；
  把 `build.bat` 整体改写成 PowerShell（改动面太大）。
- 影响 / 约束: 改日志链路要同步更新 `ISSUE-001` 判据；`tools\` 随仓库入库、别删；控制台内容 = 日志文件内容（tee 之外只剩 build.bat 的两行提示）；
  验证方式：跑 `tmp\` 里的假子脚本（禁跑 `build.bat`，见 `ADR-004`）—— 中途 `type` 已见行 + 控制台流一致 + 退出码回传。

## ADR-011 新增独立发布脚本 `gh-release.bat`：以「最后一个提交」为发布对象，只做 gh
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: `build.bat` 把 递增版本 → 编译 → commit/push → tag → `gh release` 串成一条**不可逆**的链；
  gh / 网络 / 登录一出问题（`ISSUE-005` 那类瞬断），想“只补发 Release”就得重跑整条链（还会再吃一个 `versionCode`，`ISSUE-002`）。
  需求 = 单独一个脚本，用**最后一个提交**补发 Release。
- 决策: 新增仓库根 `gh-release.bat`（与 `build.bat` 同级，可双击）：**不递增版本、不提交、不编译**。
  ①标签名取自 `version.properties`（真源，`ADR-005`）；②标签强制指向 HEAD（`git tag -f -a`），已存在但指他处时先警告 + 要求输入 `y` 确认；
  ③未推送则先 push main → push tag（失败回落 `-f`，复用 `:git_push` 3 次重试，`ADR-009`）→ `:gh_release` 幂等建/更新 Release + 上传 APK；
  ④Release 说明 = `ClipboardMerger vX.XX (build N) | <HEAD 短哈希 + 提交标题>`；⑤APK 定位顺序 = 根目录 `ClipboardMerger-v<ver>-<code>.apk`
  → 根目录任意 `*.apk` → `build\outputs\apk\debug\*.apk`；⑥`gh-release.bat check` = 只读预检（打印将执行的命令）；可显式传 `<tag> [apk]`；
  `GH_EXE` / `GH_REPO` 支持环境变量覆盖（为测试）。
- 理由: 发布失败可单独、幂等重试；脚本不碰版本号与工作区 ⇒ 重跑不污染 git 历史；`check` 让“发布前看一眼”零成本。
- 备选与为何不选: 让 `build.bat` 改成 `call gh-release.bat`（要动发布主链路，风险大，本轮不动 —— 代价是两处 `:gh_release` 有漂移风险）；
  给 `build.bat` 加子命令（仍要改频繁变动的 `build.bat`）；手敲 `gh release create`（标签 / 推送 / 幂等 / APK 定位都要手打，易漏）。
- 影响 / 约束: 脚本只对 HEAD 生效（要发旧提交得先切过去）；改 `:gh_release` 行为要两处一起改；
  动态文本（提交标题）拼命令行前必须消毒（`PIT-025`）；抽段测试必须从**标签行**切（`ISSUE-006`）；`build.bat` 自身行为未改动。
- 追加（2026-09-23 实跑后）: ①**远端标签已指向 HEAD 就跳过打标签 / 推标签** —— 用
  `gh api repos/{repo}/commits/{tag} --jq .sha` 取远端标签指向的提交（取值要 `for /f "usebackq"` + `call "带空格路径"`，见 `PIT-023`；
  走 HTTPS 从而绕开卡死的 SSH；取值为空则退回原逻辑）；②代理：设 `GH_PROXY` 即导出 `http_proxy` / `https_proxy` 给 gh / git(HTTPS)，未设时用 `curl -x` 探测 `127.0.0.1:7897`（通了自动用，探测失败照旧直连）；
  ③`:gh_release` 的更新分支发现 Release 是**草稿**时改用 `release edit --draft=false` 一并发布（否则传了 APK 也“看不见”）；
  ④开头**自我重启一次**（`PIT-026`：新 cmd 的起始代码页即 65001）+ 注释行保持 ASCII 兜底 —— 新控制台下 0 垃圾报错；
  ⑤**日志**：复用 `tools\tee-log.ps1`（`ADR-010` 的 tee 包装器）—— 每条输出**先落盘 `build\logs\gh-release_<ts>.log`（UTF-8 BOM、AutoFlush）再回显控制台**，
  跑完打印日志路径并回传退出码；缺 `tee-log.ps1` 时退回「重定向 + 结束 `type`」的降级分支（同 `build.bat`）。
