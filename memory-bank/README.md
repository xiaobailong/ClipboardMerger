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
| 日志开关关了还有输出 / 仍建 Download\ClipboardMerger 目录 | `ISSUE-003` | I |
| 构建走到“提交版本变更”就停（不 commit/tag/release） | `ISSUE-004` | I |
| `build.gradle.kts` 报 `Unresolved reference: text / util` | `PIT-022` | P |
| `'C:\Program' is not recognized`；一行 `if/else` 后接 `& 命令` 不执行 | `PIT-023`、`PIT-024` | P |
| 只补发 / 重发 GitHub Release、`gh-release.bat` 用法 | `ADR-011` | D |
| `bat` 调 `bat` 不带 `call`；中文注释被错解析；抽段测试误跑主流程 | `PIT-025`、`PIT-026`、`ISSUE-006` | P + I |
| 工具栏“三个点”下拉 / 关于弹框的构建信息 | `ADR-008` | D |
