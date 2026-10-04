# Actual test results

Tested locally on **2026-10-04 (UTC+08:00)**. Windows build 22631 (23H2),
Codex CLI **0.160.0**, Git 2.55.0. Production code uses PowerShell and .NET only.

| Suite | Runtime | Result |
| --- | --- | --- |
| Acceptance tests (including actual npm execution and uninstall compatibility) | Windows PowerShell 5.1.22621.5909 | 33/33 PASS, 0 NOT RUN |
| Acceptance tests (including actual npm execution and uninstall compatibility) | PowerShell 7.6.5 | 33/33 PASS, 0 NOT RUN |
| Independent uninstall guard review | PowerShell 5.1 / 7 | 21/21 PASS each |
| Storage fault and tamper tests | Windows PowerShell 5.1.22621.5909 | 8/8 PASS |
| Storage fault and tamper tests | PowerShell 7.6.5 | 8/8 PASS |
| Real Codex install → hooks → safe delete → undo → uninstall | Codex 0.160.0 / Windows PowerShell | PASS |
| Desktop deletion and recovery | Windows Codex Desktop 26.930.3930.0 | PASS: file and recursive directory deletion intercepted; both restored with original bytes |
| Desktop danger commands | Windows Codex Desktop 26.930.3930.0 | 5/5 DENY; fixture bytes unchanged |
| Desktop E2E release gate | Windows Codex Desktop 26.930.3930.0 | PASS: real install, full restart, file/directory recovery, danger DENY and default uninstall; no manual merge |

The latest Desktop run used the real default user installation on package
**26.930.3930.0**. `install.ps1` exited 0 and verified an enabled/trusted
Hook. The operator fully exited and reopened Desktop. All 13 prior Desktop
processes and both prior Desktop backend processes were gone. Tests resumed
in this actual Desktop session, using only synthetic local fixtures.

Actual `Remove-Item` file deletion and `Remove-Item -Recurse -Force` directory
deletion were intercepted. Original paths disappeared and all original
bytes remained in recoverable trash. Actual `safedelete undo` restored
both at their original locations, including files at two directory depths;
the records became restored and the trash payloads were gone.

Actual commands `Remove-Item -Recurse -Force .`, deletion of `.git`,
deletion of `.env`, `git clean -fd` and `git reset --hard` were each rejected
by the PreToolUse Hook. All five fixture files retained their original bytes.
The `.git` fixture was synthetic; real repository metadata was never selected.

Desktop restart really changed its `SKY_CUA_NATIVE_PIPE_DIRECTORY` value:
the complete configuration hash differed from the installed hash. Without
a manual configuration merge or any stored-hash edit, the ordinary
`uninstall.ps1` exited 0 in an independent local PowerShell process. Original
`config.toml` bytes and User PATH matched their pre-install checksums.
The new `hooks.json` and installation directory were absent. Project
recovery history remained. The complete Desktop E2E is **PASS**.

The initial release gate failed because Desktop pipe rotation triggered
the old exact-hash guard; that failed result and manual cleanup remain in
local evidence. The explicitly authorized fix changes only `uninstall.ps1`
and `src/InstallState.ps1`. It accepts a unique single-line MCP pipe value
rotating between valid `codex-computer-use` GUID named pipes only when
restoring just that value in memory reproduces the full installed SHA-256.
Other bytes, ambiguous TOML, Hook/PATH changes and corrupt backups remain
rejected. Deletion, storage, restore and Hook code are unchanged.

The new regression runs passed all 33 cases in both PowerShell versions. Three
additional cases cover valid rotations with UTF-8/BOM/line endings, 16 refused
changes with no writes, and actual isolated install/uninstall while configuration,
Hook and PATH conflicts remain protected. Both complete JSONL files were fully
parsed: 66 PASS, zero parse errors, FAIL or NOT RUN; all nine recorded source
hashes still match the tested files.

The updated real CLI integration run also passed. Two earlier supplemental CLI
attempts failed before registration because the test supplied duplicate-cased
Windows proxy environment names. Normalizing only the test environment fixed
this; the production Hook registration implementation did not change. Failed
attempts remain in ignored local evidence and are not counted as PASS.

The isolated CLI integration test uses a fixed model fixture served only on loopback. No
remote model, authentication or user files are used. Non-local proxy traffic is
blocked. The isolated CLI uses `danger-full-access` because nesting the Windows
Codex sandbox was unavailable; Hook trust is enabled normally and never bypassed.
This proves Hook execution and command replacement, not OS sandbox enforcement.

The acceptance suite actually moves and restores `test.txt` and a directory
containing multiple files. It checks `rm`, `del`, `erase`, `rmdir`, `rd`,
`Remove-Item`, root deletion (`Remove-Item -Recurse -Force .`), `.git`, `.env`,
`.ssh`, protected descendants, batches over 1000 nodes, multi-item preflight,
restore conflicts, Unicode paths, shell wrappers, dynamic/compound commands,
Git destructive commands and alias definitions. Ordinary `git status`, source
editing and Hook allow decisions are checked. Missing Hook modules fail closed.
Both final runs verify that the eight production scripts and acceptance script kept their
SHA-256 hashes throughout execution and still match the delivered code.

The separate **actual npm execution** check uses Node **v24.19.0** and npm
**10.9.4**, offline, with its cache inside the fixture. It requires a zero exit
code, npm's printed `node -e` command, and a marker written by that Node script.
The portable npm archive was downloaded only into ignored local test evidence;
the product has no npm dependency. Archive: 2,714,849 bytes;
SHA-256 `4BFBA8A0C823024D1926EC9D97A37A00EB60FD2ADF44B3D34A686FC32E8F51E4`.
Sources: [npm metadata](https://registry.npmjs.org/npm/10.9.4),
[npm test documentation](https://docs.npmjs.com/cli/v10/commands/npm-test/).

An additional run without npm reported **27 PASS, 0 FAIL, 1 NOT RUN** (installation
checks omitted in that audit), confirming missing commands cannot be counted as
successful execution. The original MVP JSONL results were fully parsed: 60 acceptance
records, 60 PASS, no parse errors and no NOT RUN entries. No real user Codex
configuration or user PATH was changed by these isolated tests.

The real integration run verified:

- The actual installer enables and trusts the hook, including an initial
  `features.hooks = false` configuration and an existing unrelated hook.
- Installation and Hook execution work with a directory named `installed $literal's`.
- A real `apply_patch` Delete File is denied and the original bytes remain.
- A real `apply_patch` Update File changes source successfully.
- A real `exec_command` deletion in `child/` is replaced with SafeDelete.
  Only `child/test.txt` moves to trash; the different root `test.txt` stays intact.
- `undo` restores the exact original bytes.
- The actual uninstaller removes its files and restores the original
  `config.toml` and `hooks.json` byte for byte.

Storage fault tests use actual locked files to interrupt moves and restores.
They verify pending recovery, retry after interrupted restore, conflicts,
tampered recovery paths, sensitive files injected into trash, junctions in
payload/history/lock paths, and missing payload errors.

Final local evidence (ignored by Git; full output stays on this machine):

- `tests/.work/storage-faults-5-20261004-050630-7f8d9302/report.json`
- `tests/.work/storage-faults-7-20261004-050633-fe7a1eac/report.json`
- `tests/.work/codex-hook-20261004-131641-6d0c1f9a/results.json`
- `tests/.work/20261004-132216-5-ecd32dea/results.jsonl` and `summary.json`
- `tests/.work/20261004-132217-7-6e5e2c81/results.jsonl` and `summary.json`
- `tests/.work/20261004-132041-7-0de54104/summary.json` (missing-npm audit)
- `tests/.work/20261004-142055-5-6bf95239/results.jsonl` and `summary.json` (33 cases)
- `tests/.work/20261004-142052-7-a609e6cb/results.jsonl` and `summary.json` (33 cases)
- `tests/.work/codex-hook-20261004-142803-b14e5d6a/results.json` (updated CLI PASS)
- `tests/.work/codex-hook-20261004-142327-9c3e394a/results.json` and `codex-hook-20261004-142621-d2ac80ff/results.json` (failed test-environment attempts)
- `tests/.work/guard-review-d79a039e504b4cb086dc6865c6109918/report-5.json` and `report-7.json`
- `work/desktop-final/restart.json`
- `work/desktop-final/file-delete.json` and `file-undo.json`
- `work/desktop-final/folder-delete.json` and `folder-undo.json`
- `work/desktop-final/danger-commands.json`
- `work/desktop-final/config-change.json` (private configuration snapshots are also ignored)
- `work/desktop-final/uninstall-result.json` and `report.json` (initial failed gate)
- `work/desktop-fixed/install.json`, `restart.json`, file/folder delete and undo reports
- `work/desktop-fixed/danger-commands.json`, `uninstall.json` and `report.json` (final PASS)

To repeat:

```powershell
pwsh -File .\tests\acceptance.ps1
powershell -ExecutionPolicy Bypass -File .\tests\acceptance.ps1
pwsh -File .\tests\storage-faults.ps1
powershell -ExecutionPolicy Bypass -File .\tests\storage-faults.ps1
python .\tests\codex-hook.py
```

The acceptance suite needs Git; its separate npm execution test needs Node/npm.
If npm is absent, that execution test is explicitly NOT RUN, never PASS. You
can supply an existing npm CLI with `-NpmCliPath <path-to-npm-cli.js>`.
For the exact local npm runs above, add
`-NpmCliPath .\tests\.work\tools\npm-10.9.4\package\bin\npm-cli.js`
to each acceptance command. The downloaded archive is not committed.
The real Codex test needs Python 3 (standard library only) and a local `codex.exe`.
These are test tools, not production dependencies.

Not tested: a separate Windows 10 machine, npm's
`codex.cmd` launcher, other command shells and arbitrary indirect deletion
programs. This tool is not an OS sandbox or a backup system.

Hook protocol sources: [official Hooks documentation](https://learn.chatgpt.com/docs/hooks),
[Codex 0.160.0 local Hook trust implementation](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/tui/src/hooks_rpc.rs).
