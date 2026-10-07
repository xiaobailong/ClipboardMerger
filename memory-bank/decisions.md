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
  `incrementVersion` 任务负责递增；APK 固定命名 `JianJi-v<versionName>-<versionCode>.apk`；
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
  ④Release 说明 = `剪集 vX.XX (build N) | <HEAD 短哈希 + 提交标题>`；⑤APK 定位顺序 = 根目录 `JianJi-v<ver>-<code>.apk`
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

## ADR-012 绑定App 提醒：通知换新渠道 ID + 全屏 Intent，提醒页改“可见卡片 + 拿到焦点后再调选择器”
- 日期: 2026-10-01 | 状态: 已采纳
- 背景: 华为 LIO-AN00m(SDK 31) 上 v1.75~v1.79 的“通知 + 透明 Activity 弹输入法选择器”全线没让用户看到提醒（`ISSUE-007`）。
- 决策: ①通知渠道**换新 ID** `bind_app_channel_v2`（HIGH + 振动 + badge），并删掉旧 ID `bind_app_channel` —— 渠道属性创建后不可变，改代码或对同一 ID delete+重建都无效；
  ②通知加 `setFullScreenIntent(pendingIntent, true)`（+ `USE_FULL_SCREEN_INTENT`）：设备在用时会退化成悬浮横幅，息屏/锁屏时直接拉起提醒页；
  ③`PickerActivity` 从“透明 + onCreate 里调选择器 + 1.5s 自动 finish”改成“可见半透明卡片 + `onWindowFocusChanged(true)` 后延迟 400ms 调、1.5s 无果补一次 + 三个手动兜底按钮 + 焦点回来即 finish（+ 60s 兜底关闭）”。
- 理由: 选择器能否弹出由 IMMS 的“当前焦点窗口 client”决定（`canShowInputMethodPickerLocked()`，与厂商无关）⇒ 必须先把窗口焦点拿到手；提醒的可见性不能只靠渠道属性（不可变）和普通通知。
- 备选与为何不选: 沿用旧渠道 ID + delete&重建（v1.79 实测无效，被用户静音过的渠道也不会恢复）；继续用透明 Activity（拿不到/来不及拿焦点，且用户看不到任何提示）；只靠 `ACTION_INPUT_METHOD_SETTINGS`（能用但把人甩到设置页，仅作兜底）；直接 `setInputMethod()` 切输入法（系统只允许“当前输入法 / 系统”调用，普通应用做不到）。
- 影响 / 约束: 换渠道 ID ⇒ 老渠道的静音设置作废、系统设置里会多一条“输入法切换提醒”（旧 ID 已删除）；`setFullScreenIntent` 在息屏/锁屏时会直接弹提醒页（本就是这个功能的意图）；今后改 `PickerActivity` 的调用时机必须同步更新 `ISSUE-007` 的复发判据。

- 追加（2026-10-01 v1.83 真机复验后）: ①华为上 `importance=HIGH` 的渠道**没有声音就没有横幅**（EMUI 当静默通知；实测 `notificationsEnabled=true, importance=4, shouldVibrate=false`）⇒ 渠道换 `bind_app_channel_v3` 并带 `setSound(...)`（`PIT-031`）；
  ②提醒门从“2 分钟内存冷却”改成“**每次进入绑定 App 提醒一次**”（离开前台即重置，只留 15s 防抖）—— 旧实现让用户看到“抖音来回开好几次，只有第一次有提醒”；
  ③不再把可见性全押在横幅上：授予「显示在其他应用上层」(`SYSTEM_ALERT_WINDOW`) 后由前台服务**直接 `startActivity` 拉起提醒卡片**（该权限同时是后台启动 Activity 的豁免条件），通知保留为兜底；绑定 App 保存时自动弹「去开启」引导。
- 追加（2026-10-01 v1.84，用户反馈“点击后有两层弹框”）: 提醒页改为**默认完全不可见**（透明窗口 + 卡片 `GONE`，窗口只用来拿焦点调选择器），只有 [CARD_FALLBACK_DELAY_MS]=1.6s 后仍没失焦（= 选择器被系统拦下）才把兜底卡片显出来 ⇒ 正常情况下用户只看到**一层**（系统输入法选择器）；选择器关掉后本页自动 `finish()`。另在「更多」菜单加「悬浮提醒权限」入口（状态 + 一键跳授权页），因为华为不会给横幅、用户必须能自己找到这个开关。
- 追加（2026-10-01 v1.85，用户问“静音/振动/免打扰没通知”）: 结论 = 通知这条路在华为上无解（横幅会被这几种模式整条吞掉），**提醒的主通道改成自绘悬浮气泡**（`BindAppBubble`：`TYPE_APPLICATION_OVERLAY` + `FLAG_NOT_FOCUSABLE`，不抢焦点）+ 直接 `Vibrator` 振动（`VibrationEffect.createOneShot`），两者都不经过通知系统；通知仅在“没有悬浮权限”时作为兜底。取舍：气泡需要一次「显示在其他应用上层」授权（已在更多菜单里给入口），换来的是**全模式可见**；气泡只在绑定 App 在前台时存在（离开即 `hide()`），点气泡才打开提醒页。
- 追加（2026-10-01 v1.86，用户要“开关 + 去掉常驻通知 + 列表搜索”）: ①「更多 → 提醒设置」新增两个持久化开关（都在 `clipboard_merger_settings`）：`bind_app_reminder_enabled`（悬浮提醒总开关：关掉即无气泡、无提醒通知，并 `cancel(BIND_NOTIFICATION_ID)`）与 `background_service_enabled`（后台监听服务：关掉即 `stopService` ⇒ 常驻通知随之消失 —— Android 要求前台服务必须挂通知，这是**唯一**能彻底去掉常驻通知的办法）；②绑定 App 列表加**搜索框**（应用名 + 包名匹配，过滤时保留当前选中项）。取舍：关掉后台服务会一并停掉后台剪贴板监听与悬浮提醒（改由「剪集输入法」面板负责），已在开关说明与 Toast 里写明。
- 追加（2026-10-01 v1.87，用户追问“常驻通知能不能别一直显示”）: 平台约束 = **前台服务必须有一条通知**（Android 8+，无法只靠 API 去掉），所以给两条路：
  ①「后台监听服务」开关关掉 ⇒ 服务停、通知消失（代价见上）；②新增「**隐藏常驻通知**」开关（`hide_persistent_notification`）= 常驻通知改用 `IMPORTANCE_NONE` 的渠道（`clipboard_service_channel_hidden`）——
  通知记录照旧提交（`startForeground` 成立、服务不被杀），但系统不展示；渠道属性不可变 ⇒ 两条渠道 ID 二选一、切换时 `stopService` + 重新拉起服务重建渠道与通知。风险：个别 ROM 可能因“服务没有可见通知”缩短后台存活时间，因此做成用户可关的开关并在说明里点明“发现剪贴板不再收集就关掉它”。
- 追加（2026-10-01 v1.88，用户反馈“一键清理后 App 不做自拉起，后台监控消失”）: 新增 `KeepAlive`（自拉起三件套：`BootReceiver` 开机/更新、`onTaskRemoved` + `AlarmManager` + `PendingIntent.getForegroundService`、输入法服务启动时补拉）+ 「更多 → 后台保活设置」（说明页 + 打开应用信息 + 申请忽略电池优化，`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）。设计取舍：**把输入法服务当锚点**是最可靠的自救点（用户点输入框系统必然拉起剪集输入法），因此把"补拉后台服务"挂在它身上；被系统 force-stop 后不做无意义的轮询自拉起（Android 不允许），改为在说明页讲清系统侧该怎么设。
- 追加（2026-10-07，并入已删除的 `handover-bind-app.md` 里仍有用、KB 原先没有的实现细节）: ①**前台 App 检测** = `usageStatsManager.queryEvents(now-15s, now)` 取 `MOVE_TO_FOREGROUND`（`ClipboardService.getForegroundPackage()`）+ `Handler.postDelayed(…, 5000L)` 每 5s 一轮；v1.74 的 `queryUsageStats(INTERVAL_DAILY)` + `lastTimeUsed` 排序误差大（桌面会排在目标 App 前面），已弃用。②**应用列表可见性** = `AndroidManifest` 加 `<queries>`（MAIN intent）+ `PackageManager.MATCH_ALL`，否则 Android 11+ 只看得见约 21 个系统 App（修好后 112 个）。③**服务保活** = `startForeground()` + `FOREGROUND_SERVICE_DATA_SYNC` 声明，常驻通知走 `IMPORTANCE_MIN` 渠道（否则华为/鸿蒙下后台服务约 1.5s 被杀）。④**关键常量** = 检测间隔 `5000L`、UsageEvents 窗口 `15_000L`、提醒防抖 `15_000L`、`AUTO_CLOSE_MS=60_000L`、`PICKER_DELAY_MS=400L`、`MIN_PICKER_VISIBLE_MS=250L`、`CARD_FALLBACK_DELAY_MS=1_600L`、渠道 `bind_app_channel_v3`、通知 ID `2`、Settings key `bound_app_package`/`bound_app_label`。⑤**日志定位法** = 手机侧 `Download/JianJi/jianji_log_<yyyy-MM-dd>.txt`，关键词 grep `bound app.*foreground` / `bind app notification` / `PickerActivity` / `showInputMethodPicker` / `cooldown active` / `no MOVE_TO_FOREGROUND`。⑥历史测试机 = `HUAWEI LIO-AN00m`（Android 12 / SDK 31）。

## ADR-013 鸿蒙（HarmonyOS）分支：原生 HAP 输入法，与 Android 工程并存
- 日期: 2026-10-05 | 状态: 已采纳（分支 `harmonyos`）
- 背景: 用户主力机换成鸿蒙 7（HarmonyOS NEXT），在**卓易通**（安卓兼容容器）里装本 APK 后**不被识别成输入法**（`PIT-034`）。鸿蒙已不原生跑 APK，输入法只能由原生 HAP 通过 `InputMethodExtensionAbility` 注册（官方《实现一个输入法应用》：`type: "inputMethod"` + `metadata: ohos.extension.input_method`）。
- 决策: ①新建分支 `harmonyos`（分支名 = 鸿蒙的英文名）；②仓库内新增 `harmony/` DevEco 子工程（根 Gradle 不 include，两套构建互不影响）；③`entry` 模块 = 输入法 Extension（键盘）+ 设置页 UIAbility；④键盘 UI 移植 Android 版 IME 面板语义（点一条=插入、多选=合并插入、退格/回车/刷新/清空、单条删除），历史存储用 preferences（去重规则、上限 5000 对齐 `ClipboardRepository`）；⑤bundleName 与 Android 版相同（`com.example.clipboardmerger`）；⑥日志沿用「hilog + 沙箱文件 + 持久化开关」（对齐 `Logger`）。
- 理由: 只有原生 HAP 能拿到「默认输入法」身份；`harmony/` 独立目录 ⇒ Android 侧构建/发布流程零改动。
- 备选与为何不选: 继续改 Android 侧（Manifest / targetSdk / 权限）期待容器放行 —— 容器内的 IME 注册不到宿主鸿蒙，改多少都没用；做成 AppGallery 上架包 —— 当前自用，先走 DevEco 自动签名。
- 影响与约束: ①输入法 Extension 受「基础访问模式」约束**不能联网** ⇒ GitHub 同步只能在 `EntryAbility` 侧实现；②API 12+ 读剪贴板需 `ohos.permission.READ_PASTEBOARD`（受限 user_grant，可能要 ACL），拿不到就只剩键盘功能，设置页会显示错误码；③鸿蒙版版本号在 `AppScope/app.json5`，与 `version.properties` 各自管；④**本机没有鸿蒙 SDK**，ArkTS 代码只做了静态检查，待 DevEco 编译 + 真机复验（未验证点列在 `harmony/README.md`）。
- 复用入口: `harmony/README.md`（构建 / 签名 / 启用输入法 / 与 Android 版差异）
- 追加（2026-10-05 首次真编译 + 发布）: 工具链 = 华为 **command-line-tools v26.0.0.851**（含 hvigor 6.26.8 / ohpm / node / `sdk\default\{openharmony,hms}`，HarmonyOS SDK API 26）；`build-harmony.bat` 端到端验证通过（自动找到工具链 → `BUILD SUCCESSFUL` → 产物收成 `build\harmony\JianJi-HarmonyOS-<版本>.hap`，默认不碰 git）；已推送分支 `harmonyos` + tag `harmony-v1.89` + Release（附件为**未签名** HAP）。真机安装仍缺**华为签名**：路径①DevEco 自动签名（GUI，需账号）；路径②AGC 网页手动签名（本地 keytool 生成 .p12+CSR → 换 .cer + 调试 Profile(.p7b) → `sdk\...\toolchains\lib\hap-sign-tool.jar` 签）。API 26 与旧文档的 4 处接口差异见 `PIT-036`。


## ADR-014 鸿蒙输入法选择列表：App 内自绘中文列表（不再用系统选择器；暂不用 InputMethodListDialog）
- 日期: 2026-10-07 | 状态: 已废弃（被 ADR-015 取代：App 内输入法入口与弹框已按用户要求删除）
- 背景: 主界面状态条点开的是系统选择器 `showOptionalInputMethods()` —— 列的是输入法自身的**英文标识**、无法本地化、API 18 起 deprecated；用户看不出哪个是「剪集」。同时 App 侧无法保证能直接切换（`PIT-047`），需要给用户一条能走通的路。
- 决策: ①在 `Index.ets` 自绘「切换输入法」弹框（`dialog === 'ime'`）：行数据 = `getAllInputMethodsSync()` 的 `label`（中文）+ 包名副行 + 「当前使用 ✓」/「剪集 · 点此启用」徽标；点行 `switchInputMethod()`，失败兜底跳系统「输入法设置」页；②原系统选择器**降级**为弹框内「系统选择器」按钮（兼容旧版本/异常场景）；③暂不接 IME Kit 的 `InputMethodListDialog`（`@ohos.inputMethodList.d.ets`，面向系统应用与输入法应用、系统渲染，文案/样式不可控，也解决不了“中文名”诉求）。
- 理由: 只有自绘列表能把“哪个是剪集”讲清楚（中文 label + 徽标），并且在同一处给出三条出路（直切 / 系统选择器 / 输入法设置）。
- 备选与为何不选: ①继续用系统选择器 —— 英文标识 + deprecated；②用 `InputMethodListDialog` —— 文案/版式不可控，且要 `CustomDialogController` 与系统版式耦合；③让键盘进程代切（键盘能切：`KeyboardController.switchIme`）—— 剪集不是当前输入法时键盘进程不保证活着，不可靠。
- 影响与约束: ①“直切”受 `switchInputMethod` 限制，兜底跳转是硬要求（`PIT-047`）；②列表只反映系统**已启用**的输入法，剪集未启用时用红字引导去「输入法设置」勾选；③键盘内「⚙ → 切换目标」仍归键盘沙箱自持（`PIT-039`），与 App 侧列表互不替代。
- 复用入口: `harmony/entry/src/main/ets/pages/Index.ets` 的 `openImeList / switchToIme / findImeProperty / imeListHeight`

## ADR-015 去掉 App 内的输入法切换入口与弹框（状态条改只读，切换只走系统「输入法设置」页）
- 日期: 2026-10-07 | 状态: 已采纳（取代 ADR-014）
- 背景: ADR-014 在 App 内自绘了「切换输入法」弹框（`dialog === 'ime'` + `openImeList/switchToIme/findImeProperty/imeListHeight/showImePicker`）。用户明确要求：**去掉状态条点击后的动作，并删掉相应弹框**。
- 决策: ①`@Builder topBar()` 去掉 `.onClick`，状态条改为**只读展示**（左 = 条数 / 已选，右 = `输入法: 已激活 ✅` 或 `未激活 ⚠️ 当前：xxx`），文案去掉「点此切换」；②删除弹框分支 `dialog === 'ime'` 与 5 个专用方法、2 个状态（`curImeId` / `ownRegistered`）；③App 内不再提供任何切换/弹出选择器入口 —— 切换输入法统一走「更多 → 权限设置 → 输入法设置」（`openImeSettings()` 保留，跳系统设置页，中文列表）。
- 理由: App 侧本来就无法可靠切换（`PIT-047`：`switchInputMethod` 要求调用方是当前输入法），自绘列表点一行大概率还要跳系统页 —— 两层入口反而绕；状态条只需表达「现在是不是剪集、当前是谁」。
- 备选与为何不选: ①保留弹框但禁用点击（死代码，入口语义矛盾）；②只在「未激活」时可点（用户要求直接去掉动作，未给条件）；③改回系统 `showOptionalInputMethods()`（英文标识 + API 18 起 deprecated）。
- 影响与约束: ①主界面不再能一键切到剪集，用户走系统设置页；键盘内的「切换」键（`KeyboardController.switchIme`，`PIT-039` 沙箱自持）不受影响；②`PIT-047` 的「App 侧失败兜底」讨论随之作废（App 侧已无该入口，该条已加追加说明）；③`ISSUE-008` 的复发判据已按本条修订（`'ime'` 分支不应再出现）；④`inputMethod.switchInputMethod` / `showOptionalInputMethods` 在 App 进程不再被调用 ⇒ 构建日志少一条 deprecated 告警。
- 复用入口: `harmony/entry/src/main/ets/pages/Index.ets` 的 `topBar() / imeBarText() / countText() / openImeSettings()`

## ADR-016 鸿蒙装机独立成 `deploy-harmony.bat`（走 hdc 调试通道，完全不碰 git）
- 日期: 2026-10-07 | 状态: 已采纳
- 背景: 出包（`build-harmony.bat`）与装机一直靠手工敲 `hdc install -r …` + `aa force-stop`，而手工步骤在本项目反复踩坑：忘了 force-stop ⇒ 输入法进程跑旧代码（`PIT-040`）；没确认 `install bundle successfully` ⇒ 以为装上了（`PIT-044`）；拿旧包当新包（`PIT-029`）；`hdc` 不在 PATH（`PIT-036`）；设备 `Unauthorized` 时不知道怎么恢复（`PIT-045`）。
- 决策: 新增仓库根 `deploy-harmony.bat`（与 `build-harmony.bat` 平级，**只做装机**）：①自动找 `hdc.exe`（`HOS_CLT` 默认 `D:\Tools\DevTools\hmos\command-line-tools` → `DEVECO_HOME` → 常见 DevEco 安装目录 → `PATH`）；②`list` 子命令只查设备；③默认装最新构建的 `harmony\entry\build\default\outputs\default\entry-default-signed.hap`，也可传 HAP 路径；④`install -r` 保留数据；⑤装机后 `aa force-stop`；⑥读 `tools\harmony-version.js` 与 `bm dump -n <bundle>` 比对 versionName；⑦尝试 `aa start` 拉起 App（锁屏被系统拒时给提示而非报错）；⑧日志走 `tools\tee-log.ps1` → `build\logs\deploy_<ts>.log`；⑨**不含任何 git 操作**。
- 理由: 装机是高频动作且失败模式都有明确判据 ⇒ 固化成一个脚本可一次性消灭上述 5 个坑；「出包 / 装机 / 发布」三件事分离，各自可单独重跑（发布仍只在 `build.bat` 与 `build-harmony.bat release` 里）。
- 备选与为何不选: ①给 `build-harmony.bat` 加 `install` 开关 —— 出包与装机混在一条命令里，失败时说不清是编译还是装机的问题，也违反 `PIT-044` 铁律 1（构建与装机必须分成两条命令）；②继续手工敲命令 —— 就是上面那些坑的来源；③用 DevEco Studio 的 Run —— 要 GUI + 账号，命令行/自动化场景用不上。
- 影响与约束: ①脚本只认「已构建好的签名 HAP」，找不到会提示先跑 `build-harmony.bat`；②`-r` 在个别机型（HLS-AL00）不顶用，失败分支给出 `uninstall` 兜底命令（会丢数据，需人工决定）；③「手机锁屏 ⇒ 拉不起 App」是系统限制（`10106102`），脚本只提示，不算失败（装机本身已成功，退出码 0）；④`.clinerules` 的目录结构清单与 `harmony/README.md` 已同步登记该脚本。
- 复用入口: `deploy-harmony.bat`、`harmony/README.md` 的「装机脚本 `deploy-harmony.bat`」一节
