# archive / decisions-archive.md（**默认不读**）

> 放已废弃 / 被取代的 `ADR-nnn` 原文（按时间倒序追加）。
> 归档时保留「被 ADR-xxx 取代」关系；`decisions.md` 原位置改成
> `## ADR-nnn <标题> — 已废弃（被 ADR-xxx 取代）：见 archive/decisions-archive.md`。

## ADR-001 知识库制度：`memory-bank` 按需读取 + 体积阈值 + 归档（控 token）
【归档 2026-09-23，超限移出（仍是已采纳状态），原文】
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: 同一个坑（WMI 挂死、`-Command` 786、批处理变量展开、日志写不进文件…）在不同会话被反复重查；
  但"每次把知识库整篇读完"又会白烧上下文，挤压留给代码/任务的窗口。
- 决策: ①知识库拆成"**数据（按需读）** + **规则（常驻）**"：索引 `memory-bank/README.md`（≈1.5KB，开工只读这个）、
  条目 `issues-solved.md`(I) / `pitfalls.md`(P) / `decisions.md`(D)、写法 `memory-bank/WRITING.md`（模板 / 归档 / 阈值，**只在要写条目时读**）、
  归档 `archive/`（默认不读）；规则本体在 `.clinerules/memory-bank.md`（常驻，已付过费）（2026-09-23 第二轮优化：原先把协议/模板塞在索引里，等于每次会话重复付费）；
  ②读取按需：**只读索引 → 只读命中的那 1 个文件 → `archive/` 默认不读**；
  ③主文件设上限（索引 2.5KB、`I`/`P`/`D` 各 12KB），超了先归档再写新条目。
- 理由: 一条"结论 + 复发判据"只占几行，却能把几十分钟的排查压成一条命令；
  按需读 + 归档 + 规则常驻后，每次会话约 `.clinerules` 1.6k tok + 索引 0.45k tok + 命中的那 1 个文件（0.9~3.3k tok）。
- 备选与为何不选: 写进 `README.md`（污染产品文档）；只靠 commit message（不可检索、无判据）；
  外部 wiki（离线/跨机不便）；无脑 read all（正是要避免的 token 浪费）。
- 影响 / 约束: 每个任务结束必须回填条目 + 更新索引；条目只写结论与判据，长推导进 `archive/` / `docs\`；
  不许删条目、不许改编号；条目禁止写 token / 凭据。
  落地自检（临时脚本放 `tmp\`，用完即删）：统计各文件 bytes / ~tok 是否超阈值 + 校验 `enc=noBOM CRLF` +
  交叉引用（引用的 `ISSUE/PIT/ADR` 编号是否都存在，防悬空指针）。

## ADR-003 构建日志用「`call` 递归 + 文件重定向」，放弃「管道 + PowerShell 追写」
【归档 2026-09-23，已废弃（被 ADR-010 取代），原文】
- 日期: 2026-09-22（`d21ff87` → `f9bc43c` → `bccd4ca`）| 状态: 已采纳
- 决策: `build.bat` 顶部用 `goto :init_log` / `:skip_log`（不用括号块）→ 日志
  `build\logs\build_<yyyyMMdd_HHmmss>.log`（首行由 PowerShell 写 UTF-8 BOM）→
  `call "%~f0" %* 1>> "%_CM_LOGFILE%" 2>&1` + 紧邻 `set _CM_BUILD_RESULT=%ERRORLEVEL%` → `type` 回显。
- 理由: 重定向由 cmd 内核完成，不受 `-Command` 长度与解析期展开影响；`call` 不额外起进程、退出码可控。
- 备选与为何不选: 管道 + PowerShell `tee`（实测丢内容，`PIT-012`）；`_logpath.tmp` 传路径（多一个残留文件）；
  整体重写为 PowerShell 构建脚本（改动面太大）。
- 影响 / 约束: 改这段必须跑 `ISSUE-001` 的复发判据；`_CM_LOG_ACTIVE` 是父子进程判别关键，别改名。
## ADR-007 Token 策略：仓库侧（`.clineignore` + 精简 `.clinerules` + 检索式知识库）+ 客户端侧（Auto-Compact / `/smol` / `/newtask`）
【归档 2026-09-23，超限移出（仍是已采纳状态），原文】
- 日期: 2026-09-23 | 状态: 已采纳
- 背景: 长会话的上下文被三块吃掉：①Cline 自动扫构建产物（本仓库 `build\` 是万级文件）；②`.clinerules` 每次会话必加载；
  ③知识库若全量读，单次就是几千 token。任务历史的膨胀速度快于模型窗口。
- 决策（仓库侧，已落地）：
  - `.clineignore` 排除 `build/generated|intermediates|kotlin|outputs|tmp|reports`、`app/build/`、`.gradle/`、
    `*.apk|aab|jar|class`、`img/`、`local.properties`、`*.jks|keystore|p12|key|pem`；
    **故意不忽略 `build/logs/`** —— 那是排查构建的唯一现场（`ISSUE-001` / `PIT-016`）。
  - `.clinerules` 只留"编码 / 输出 / 目录结构 / 禁止操作 + 两条流程指针"，压到约 0.9k tok；
    细节（模板、红线、归档、读取纪律）全部在 `memory-bank/`。
  - 知识库检索式读取：索引 → 命中那 1 个文件 → `archive/` 默认不读；主文件设体积上限，超限先归档。
  - 输出侧：`.clinerules` §2 要求"先结论 / 代码、少解释；收尾只讲改动 + 验证 + `tmp\` 状态"。
- 决策（客户端侧，**需用户在 Cline 里操作，仓库文件无法配置**）：打开 `Enable Auto-Compact`；
  长会话收尾手动 `/smol`；跨天或换任务用 `/newtask`（新会话仍会按本仓库规则先读知识库索引）。
- 备选与为何不选: ①装 `memory_search` / Token Limits / Codebase Memory 之类 MCP —— 需额外安装维护，
  当前"索引 + 只读 1 个文件"已达同等效果，条目变多后再评估；②把 `.clinerules` 压到 300 tok ——
  会丢掉发布禁令、`tmp\` 归属、知识库读取纪律这些硬约束；③忽略整个 `build/` —— 会屏蔽构建日志、破坏排查链路。
- 影响 / 约束: 新增长期内容先问"是否每次会话都需要"——需要才进 `.clinerules`，否则进 `memory-bank/`；
  压缩是有损的，关键结论与复发判据必须当场结构化写进知识库（见 `memory-bank/WRITING.md` §4）。
