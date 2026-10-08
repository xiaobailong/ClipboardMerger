# memory-bank 索引（**只读需要的那 1 个文件**，别全读）

- 文件代号：`I` = `issues-solved.md`（已定位问题）　`P` = `pitfalls.md`（踩坑）　`D` = `decisions.md`（取舍）
- `archive/` **默认不读**（条目给指针才读那节）；**写**条目看 `WRITING.md`；规矩见 `.clinerules/memory-bank.md`
- 上限：本索引 2.5KB，`I`/`P`/`D` 各 12KB（超了先归档；带「已归档」字样的详情在 archive）

## 症状 → 条目

| 症状 / 报错 | 条目 | 文件 |
| --- | --- | --- |
| 构建日志空 / 缺内容 / 路径为空 | `ISSUE-001`（archive） | I |
| 构建失败也消耗一个 `versionCode`（跳号） | `ISSUE-002` | I |
| 改 `build.bat` 的日志 / 发布 / 版本流程 | `ISSUE-001` 判据、`ADR-005` / `ADR-010` | I + D |
| 校验不 push / 推送瞬断失败 / `gh` / Release 出问题 | `ADR-004` / `ADR-006` / `ADR-009` / `ADR-011`、`ISSUE-005`、`PIT-027` | D + I + P |
| 临时文件放哪、怎么清；仓库根堆临时产物 | `ADR-002` | D |
| 知识库为什么按需读、`.clineignore` / 会话压缩怎么用 | `ADR-001`（已归档）、`ADR-007`（已归档） | D |
| `powershell -Command` 无输出、退出码 786 | `PIT-001` | P |
| `.ps1` 乱码 / 语法错；`.bat` 首行 `@echo off` 失效 | `PIT-002` | P |
| 批量替换把文件改坏（字符被换 / 路径重复） | `PIT-003`、`PIT-004`、`PIT-014` | P |
| 批处理只跑一半；`echo` 里 `>` / 括号 / 变量展开出错 | `PIT-005`、`PIT-006`、`PIT-007` | P |
| 终端抓不到输出 / 命令互相打断 / 轮询被掐断 | `PIT-008`、`PIT-009`、`PIT-018` | P |
| 日志中文乱码 / PowerShell 查询挂死 / 搜不到东西 | `PIT-010`、`PIT-011`、`PIT-017` | P |
| 管道 + PowerShell 写日志丢内容；`call` 递归退出码不对 | `PIT-012`、`PIT-013` | P |
| 产物放 `build\` 被清 / 日志看不到最新 / 窗口没关又起一轮 / 日志缺一段 | `PIT-015`、`PIT-016`、`PIT-020`、`PIT-021` | P |
| 日志开关关了还有输出 / 仍建 Download\JianJi 目录 | `ISSUE-003` | I |
| 构建走到“提交版本变更”就停（不 commit/tag/release） | `ISSUE-004` | I |
| `build.gradle.kts` 报 `Unresolved reference: text / util` | `PIT-022` | P |
| `'C:\Program' is not recognized`；一行 `if/else` 后接 `& 命令` 不执行 | `PIT-023`、`PIT-024` | P |
| 只补发 / 重发 GitHub Release、`gh-release.bat` 用法 | `ADR-011` | D |
| `bat` 调 `bat` 不带 `call`；中文注释被错解析；抽段测试误跑主流程 | `PIT-025`、`PIT-026`、`ISSUE-006` | P + I |
| 工具栏"三个点"下拉 / 关于弹框的构建信息 | `ADR-008` | D |
| 绑定App：输入法选择器不弹出 + 通知不悬浮（根因 = IMMS 焦点闸门） | `ISSUE-007`、`PIT-028`、`ADR-012` | I + P + D |
| `showInputMethodPicker()`“调用成功但不弹” | `PIT-028` | P |
| 真机复验前先确认“装的到底是哪个版本”（拿旧包当新包） | `PIT-029` | P |
| 编译报 `Unresolved reference: <layout>/<id>`（资源文件丢了） | `PIT-030` | P |
| 华为渠道「无声音」⇒ 永远没横幅（importance=HIGH 也没用） | `PIT-031` | P |
| 悬浮提醒/后台服务的开关、绑定列表搜索框、常驻通知怎么去掉 | `ADR-012` | D |
| 华为「一键清理」后不自拉起（自启动≠会回来） | `PIT-033` | P |
| 静音/振动/免打扰下通知整条消失 ⇒ 提醒要绕开通知系统（悬浮窗+振动） | `PIT-032` | P |
| 鸿蒙/卓易通里 APK 不被识别成输入法；鸿蒙原生输入法怎么做 | `PIT-034`、`ADR-013` | P + D |
| 抓长文档/长源码被中间截断、查不到 IME API 定义 | `PIT-035` | P |
| IME Extension 独立沙箱：App 侧设置键盘读不到（切到百度/高度不变/报告看不到） | `PIT-039` | P |
| 改完输入法代码不 `aa force-stop` ⇒ 老进程跑旧代码（`kill -9` 不允许） | `PIT-040` | P |
| 键盘面板改高度：`resize` 要在 `setUiContent` 之后；尺寸由系统按内容算 | `PIT-041` | P |
| 面板内设置被裁掉 ⇒ `Scroll` + `scrollBar(Auto)`，别改面板高度 | `PIT-042` | P |
| ArkTS：三元不能当组件 / `bindMenu` 插项别重复 `{` / 重复 import | `PIT-043` | P |
| `deploy.bat` 的 install 被新命令打断（`^C`）⇒ 必须确认装机 | `PIT-044` | P |
| hdc 报 `Unauthorized` 且手机不弹授权框 ⇒ 换掉 `~/.harmony/hdckey*` 再重连 | `PIT-045` | P |
| 鸿蒙本机构建（命令行工具 / API 26 IME 接口 4 处差异） | `PIT-036` | P |
| 鸿蒙自动签名后仍出 unsigned 包 / 装机 already exist | `PIT-037` | P |
| ArkUI 保留成员名（`@State tabIndex` / `@Builder key()` 撞基类）⇒ 编译出一堆假错误 | `PIT-038` | P |
| 鸿蒙版：⋮→「皮肤」弹框只剩「关闭」按钮 / 状态条点出英文输入法列表 | `ISSUE-008`、`PIT-047`、`ADR-014` | I + P + D |
| 鸿蒙 `switchInputMethod` 只能由「当前输入法」调用 ⇒ 自绘列表要带兜底 | `PIT-047` | P |
| 鸿蒙 DataShare 只剩「数据代理」半边（无 `DataShareHelper`） | `PIT-046` | P |
| 鸿蒙版：切了剪集输入法，App 状态条仍显示「未激活」 | `ISSUE-009` | I |
| 脱离终端跑 hvigor：env 里写 `PATH=`（键名应为 `Path`）⇒ `spawn cmd.exe ENOENT` | `PIT-048` | P |
| 鸿蒙版 IME「删除」键删的是历史记录，编辑框选区删不掉 | `ISSUE-010`、`PIT-049` | I + P |
| 鸿蒙 IME Kit 无「取选中文本/删选区」⇒ `deleteForward` + `selectionChange` | `PIT-049` | P |
| 鸿蒙版：App 里清空/左滑删除不同步到键盘（App→IME 单向缺失） | `ISSUE-011`、`PIT-050` | I + P |
| 鸿蒙版：App 侧历史成片重复（快照合并用循环 `addText`，只挡最新一条） | `ISSUE-012` | I |
| 公共事件是广播：自己发的事件本进程也收 ⇒ 事件必须带 `src` 过滤 | `PIT-050` | P |
| 去掉 App 内输入法切换入口/弹框（状态条改只读） | `ADR-015`、`ISSUE-008` | D + I |

