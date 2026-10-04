# Codex SafeDelete

Stop AI coding agents from permanently deleting your files.

Dangerous delete commands are intercepted and made recoverable.

```powershell
.\install.ps1
```

Accidental deletion?

```powershell
safedelete undo
```

```text
Codex tries:
rm -rf src/

SafeDelete:
BLOCKED → moved to recoverable trash

safedelete undo
→ src/ restored
```

**Local Windows MVP.** No file uploads, server, account or background service.
MIT licensed.

| Environment | Verification status |
| --- | --- |
| PowerShell 5.1 / 7 on Windows build 22631 (23H2) | Verified; a separate Windows 10 machine has not been tested |
| Codex CLI 0.160.0 with a local `codex.exe` | Real Hook → trash → undo → uninstall verified |
| Codex Desktop 26.930.3930.0 | Delete/undo previously verified; full E2E retest pending after the narrow uninstall fix |

Download the project and run the install command above in its folder.

If Windows blocks a downloaded script, after reviewing it run
`powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`.
Restart Codex and open a new terminal. In Codex `/hooks`, confirm SafeDelete
is enabled and trusted. Installation verifies registration through your local
Codex app-server; an unsupported version produces an error and rolls back.

From the affected project:

```powershell
safedelete undo           # Restore the latest deletion
safedelete list           # Show records and original paths
safedelete restore <id>   # Restore an earlier deletion
safedelete delete src/    # Delete safely yourself
```

Files stay in `.codex-safedelete/trash/`. `history.json` records the original
path, name, UTC time, recovery path and triggering command. Restore never
overwrites an existing path. Keep this directory until you no longer need recovery.

Recognized commands: `rm`, `del`, `erase`, `rmdir`, `rd`, `Remove-Item` and their
literal shell wrappers. Their original execution is replaced by the local
SafeDelete CLI, which moves literal targets in the actual working directory.
`git clean` and `git reset --hard` are always denied.
Project roots, paths outside the project, `.git`, `.env`, `.ssh`, the recovery
store, `.codex`, links/junctions and batches exceeding **1000 files or directories** are denied.
Directories containing protected paths are also denied. Wildcards, dynamic
deletion paths and commands mixing deletion with other work are denied; split
the commands or use `safedelete delete` with explicit paths.

Ordinary `git status`, `npm test` and source edits pass through.
Opaque shell scripts, encoded commands and interactive shells are also denied.
Explicit `apply_patch` Delete File directives are denied; use `safedelete delete`
first. Ordinary patches continue to work.
The project is discovered from `.git` or the nearest recovery store; otherwise
the current directory is its root.

**Scope:** this is a shell-command safety net, not an operating system sandbox.
Codex must load this trusted PreToolUse hook. Arbitrary programs, custom tools,
file edits that remove content, file renames and commands sent later
to an interactive process through `write_stdin` are outside this MVP's coverage.
Do not use interactive shells or bypass the hook for deletion. The supplied
`SKILL.md` adds agent guidance; the hook handles recognized shell deletes even
without the skill. Files already permanently deleted before installation cannot
be recovered. Use an OS backup for broader protection.

Uninstall from this downloaded folder:

```powershell
.\uninstall.ps1
```

Run installation and uninstallation in a separate PowerShell terminal. The Hook
deliberately refuses opaque scripts invoked by the agent.

The installer preserves existing hooks and backs up the original Codex
configuration byte for byte. Uninstall restores it and removes its PATH entry;
project trash stays available. If configuration or PATH was changed afterward,
uninstall stops before overwriting those changes and points to the backups.
Desktop's temporary `codex-computer-use` named-pipe GUID rotation is accepted
only if restoring that value in memory reproduces the complete installed
configuration hash. Other configuration or PATH changes still stop uninstall.

See [TEST-RESULTS.md](TEST-RESULTS.md) for actual runs, commands and limits.
Node/npm and Python are test tools only; the product needs neither.

Verified Hook API: Codex CLI 0.160.0, [`hooks.json` / PreToolUse](https://learn.chatgpt.com/docs/hooks).
This MVP requires a local `codex.exe` (included with Codex Desktop) and PowerShell
as the agent's command shell. An npm `codex.cmd` launcher is not supported by
the installer yet. The Desktop results above come from actual agent commands
after a complete restart, not just a CLI or local app-server probe.
