---
name: codex-safedelete
description: Use recoverable local deletion and restore files deleted by mistake. 使用可恢复的本地删除，并恢复误删文件。
---

## English

Prefer `safedelete delete <literal-path>` for deleting files or directories.
Never bypass SafeDelete or use another method to permanently delete files.
Only when the user explicitly requests pausing protection, run `safedelete off`.
Never pause protection to work around a denied deletion. Use `safedelete on`
when the user requests resuming, and `safedelete status` to check its real state.
Do not replace blocked commands with scripts, encoded commands, APIs, or interactive shell input.

When the user says `undo`, `恢复`, `刚才删错了`, or `rollback delete` after a deletion,
run `safedelete undo` from the affected project. Use `safedelete list` and
`safedelete restore <id>` when a specific earlier deletion is requested.
If the original path exists, report the conflict; never overwrite it.

The program and Hook enforce the safety rules. This skill is guidance, not the security mechanism.

## 简体中文

删除文件或目录时，优先使用 `safedelete delete <literal-path>`，路径必须是明确的字面路径。
不得绕过 SafeDelete，也不得使用其他方式永久删除文件。
只有用户明确要求暂停保护时，才执行 `safedelete off`。
不得为了执行被拒绝的删除而暂停保护。用户要求恢复保护时，执行 `safedelete on`；
使用 `safedelete status` 检查真实状态。
不得将被拦截的命令改成脚本、编码命令、API 或交互式终端输入来执行。

删除后，用户说 `undo`、`恢复`、`刚才删错了` 或 `rollback delete` 时，
优先在受影响的项目中执行 `safedelete undo`。
使用 `safedelete list` 查看记录，使用 `safedelete restore <id>` 恢复指定记录。
如果原路径已存在内容，报告冲突，不得覆盖。

安全规则由程序和 Hook 执行。本 Skill 只提供行为指引，不是安全机制。
