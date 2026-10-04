---
name: codex-safedelete
description: Use recoverable local deletion and restore files deleted by mistake.
---

Prefer `safedelete delete <literal-path>` for deleting files or directories.
Never bypass SafeDelete, disable its hook, or use another method to permanently delete files.
Do not replace blocked commands with scripts, encoded commands, APIs, or interactive shell input.

When the user says `undo`, `恢复`, `刚才删错了`, or `rollback delete` after a deletion,
run `safedelete undo` from the affected project. Use `safedelete list` and
`safedelete restore <id>` when a specific earlier deletion is requested.
If the original path exists, report the conflict; never overwrite it.

The program and Hook enforce the safety rules. This skill is guidance, not the security mechanism.
