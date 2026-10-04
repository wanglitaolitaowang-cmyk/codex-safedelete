# Codex SafeDelete

[English](README.md) | [简体中文](README.zh-CN.md)

Local delete protection and one-command recovery for Codex on Windows.

Recognized delete commands are intercepted and moved to recoverable local
trash. `safedelete undo` restores successfully saved files and directories.

**Local only.** No account, cloud upload or background service.
**Protection scope:** recognized deletes; this Hook does not provide OS-level isolation.

## Quick Start

### Install

Double-click:

```text
Install SafeDelete.cmd
```

Reopen Codex and your terminal once. That's it.

### Accidentally deleted something?

```powershell
safedelete undo
```

![Codex SafeDelete bilingual terminal demo](assets/demo.gif)

Chinese and English captions explain actual delete-and-restore results from
an isolated Codex CLI run with a fixed local model fixture. Commands and output
are replayed excerpts; startup delays are compressed.

### Pause protection

Double-click **`Pause SafeDelete.cmd`**, or run:

```powershell
safedelete off
```

**Warning:** Codex can delete files permanently while protection is OFF.
Previously saved trash and history remain available.

### Resume protection

Double-click **`Resume SafeDelete.cmd`**, or run:

```powershell
safedelete on
```

## Check status

```powershell
safedelete status
```

`ON` means the local Hook is registered, enabled, trusted and verified.
`OFF` means its protection is paused. `UNKNOWN` means configuration needs
attention; the command returns an error instead of claiming protection.

## Uninstall

Double-click **`Uninstall SafeDelete.cmd`**.

Reopen Codex and your terminal after uninstalling to clear the running Hook and PATH.

Pause temporarily disables protection while SafeDelete stays installed.
Uninstall removes SafeDelete and restores the original Codex configuration
and PATH. Both preserve previously saved project trash and history.

```text
Codex tries:
Remove-Item -Recurse -Force src/

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
| Codex Desktop 26.930.3930.0 | Real install, full restart, deletion interception, undo and default uninstall verified |
| Mixed PowerShell 5.1 / 7 and Windows code pages 936 / 65001 | Unicode paths, binary bytes and empty directories verified |
| Windows 7 / 8, or Windows 10 before 1809 | Codex integration is unsupported; installation stops before changing configuration |
| Linux / macOS | No installer or platform adaptation yet; not supported by this release |

The full Desktop exit/restart results are from an earlier run. This MVP repair
batch did not repeat the complete GUI restart sequence; see
[TEST-RESULTS.md](TEST-RESULTS.md) for each run and retained failures.

The installer requires Windows 10 version 1809 (build 17763) or newer and PowerShell 5.1 or
newer. This follows [Codex's Windows requirements](https://developers.openai.com/codex/windows).
Windows 11 is recommended by Codex; Windows 10 support is best effort.

Pause/resume, persistence after full Desktop restarts, recovery of earlier
records and default uninstall are also verified. This machine's Desktop run
required the operator to allow 360's Hook and console-host warnings manually.
Default compatibility with 360 or other antivirus products is not proven.
A Hook blocked by security software cannot protect deletes. Review the scripts
and warning before deciding whether to permit them; the installer never changes
antivirus settings or adds exclusions. Its self-check uses a readable command.

The launchers use Windows PowerShell 5.1, require no administrator access,
and keep the result window open. Execution-policy bypass applies only to
that process; your saved execution policy is unchanged. The existing installer
checks Hook registration, trust and execution before reporting success.
If `codex.exe` is absent from PATH, it checks Codex Desktop's local binary
folder automatically. If local Codex initialization times out and rollback
finishes, first double-click `Uninstall SafeDelete.cmd` to remove the leftover
installation, then double-click `Install SafeDelete.cmd` to retry. Cleanup keeps
configuration and PATH changes made after rollback. If rollback is incomplete,
inspect the error and preserved backups before retrying.

The default program folder is `%USERPROFILE%\.codex-safedelete-app`, shared by
Explorer and Codex. MSIX desktop apps can redirect the old AppData location into
their package cache, leaving Explorer with a Hook registration but no visible
program. Installation backs up and migrates a verified legacy default install,
preserving original configuration backups, pause state and project recovery
records. Pause, resume and status also verify a retained legacy cached Hook so
its switch stays consistent until Codex restarts. Ambiguous installations, conflicts and missing valid state are preserved
with a diagnostic; registration is not removed blindly.

Repeating installation in the shared folder verifies the existing program; it does not upgrade its
files. If this checkout's program files differ, installation stops without
changing the existing installation. Use `Uninstall SafeDelete.cmd` from the
original version, reopen Codex and your terminal, then install the new version. Project trash and history are
preserved during uninstall.

For the same Windows user, installation and uninstall cannot run concurrently
against the same installation folder or Codex configuration. If either is busy,
this invocation stops without making changes. Wait for the other operation to
finish, then retry.

Installation does not append another SafeDelete hook when registration exists
without matching installation state. It stops before changing files. Hook
verification folds identical reports of the same key; distinct registrations
or conflicting metadata produce an error with the relevant source and keys.
Use the original uninstaller for an existing installation. Preserve the error
and configuration backup when installation state is missing or incomplete.

Advanced users can install from PowerShell in the extracted project folder:

```powershell
.\install.ps1
```

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

Failed deletes that moved no files do not block undo of an earlier deletion.
Content checks allow interrupted restores to finish safely; reading large files
can take longer. An interrupted record from an older version may lack these
checks and require manual recovery. Its remaining trash is preserved.

The pause switch is installation-wide and persists across Codex restarts.
It changes only `protection-state.json` in the installation folder; Codex
configuration and PATH are untouched. The Hook reads it on every invocation.
`list`, `undo`, `restore` and explicit `safedelete delete` keep working while OFF.
A missing pause-state file keeps the Hook protecting; a damaged file makes
it deny commands. Only pause when you intend to stop protection; agents must
not pause to work around a denied delete.
For versions installed before pause support, use the original uninstaller
before installing this version; the installer does not silently overwrite them.

Automatic recovery supports literal PowerShell deletion commands. With the
default Windows shell, use `Remove-Item`; ambiguous aliases such as `rm`, `del`,
`erase`, `rmdir` and `rd` require explicit PowerShell shell metadata or a
`powershell -NoProfile -Command` / `pwsh -NoProfile -Command` wrapper. Otherwise
they are denied. PowerShell wrappers must include `-NoProfile` for automatic
recovery. Directory options (`-WorkingDirectory` / `-wd`), dynamic or unknown
startup options, and unsupported deletion options are denied. Set the tool's
`workdir` to choose the working directory.
The original execution is replaced by the local SafeDelete CLI, which moves
literal targets in the actual working directory. Bash, sh, CMD and WSL deletion
is denied; use `safedelete delete` from a Windows PowerShell terminal.
`git clean` and `git reset --hard` are always denied.
Project roots, paths outside the project, `.git`, `.env`, `.ssh`, the recovery
store, `.codex`, links/junctions, case-sensitive Windows directories and batches
exceeding **1000 files or directories** are denied. If directory semantics cannot
be confirmed, including on some network shares, the command is denied.
Directories containing protected paths are also denied. Wildcards, dynamic
deletion paths and commands mixing deletion with other work are denied; split
the commands or use `safedelete delete` with explicit paths.

Ordinary `git status`, `npm test` and source edits pass through.
Opaque shell scripts, encoded commands and interactive shells are also denied.
The Hook denies the original command if its checks fail or exceed the 20-second
budget; it does not silently continue after a slow disk or worker failure.
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

To uninstall, double-click **`Uninstall SafeDelete.cmd`** in the same folder.
Your recoverable trash is preserved. Or use PowerShell:

```powershell
.\uninstall.ps1
```

Use the launchers or a separate PowerShell terminal for installation and
uninstallation. The Hook deliberately refuses opaque scripts invoked by the agent.

The installer preserves existing hooks and backs up the original Codex
configuration byte for byte. Uninstall of a completed installation restores it
and removes its PATH entry; project trash stays available. If configuration or
PATH was changed afterward, uninstall stops before overwriting those changes
and points to the backups. After a completed rollback, uninstall only removes
the leftover installation files and keeps the current configuration and PATH.
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
