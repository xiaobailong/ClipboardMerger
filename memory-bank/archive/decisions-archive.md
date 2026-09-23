# archive / decisions-archive.md（**默认不读**）

> 放已废弃 / 被取代的 `ADR-nnn` 原文（按时间倒序追加）。
> 归档时保留「被 ADR-xxx 取代」关系；`decisions.md` 原位置改成
> `## ADR-nnn <标题> — 已废弃（被 ADR-xxx 取代）：见 archive/decisions-archive.md`。

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
