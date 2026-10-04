# Actual test results

Tested locally on **2026-10-04 (UTC+08:00)**. Windows build 22631 (23H2),
Codex CLI **0.160.0**, Git 2.55.0. Production code uses PowerShell and .NET only.

| Suite | Runtime | Result |
| --- | --- | --- |
| Acceptance tests (including actual npm execution) | Windows PowerShell 5.1.22621.5909 | 30/30 PASS, 0 NOT RUN |
| Acceptance tests (including actual npm execution) | PowerShell 7.6.5 | 30/30 PASS, 0 NOT RUN |
| Storage fault and tamper tests | Windows PowerShell 5.1.22621.5909 | 8/8 PASS |
| Storage fault and tamper tests | PowerShell 7.6.5 | 8/8 PASS |
| Real Codex install → hooks → safe delete → undo → uninstall | Codex 0.160.0 / Windows PowerShell | PASS |
| Desktop E2E release gate | Windows Codex Desktop | NOT RUN: complete restart and real Desktop deletion/recovery not yet completed |

The release review identified Windows Codex Desktop package **26.930.3930.0**.
Its window and standard accessibility controls are accessible, but this review
agent runs under the Desktop process. A complete exit terminates the reviewer.
The current session has not demonstrated reliable unattended restart and
continuation. A manual restart and resumed Desktop test are required before
this gate can be marked PASS. This is an incomplete validation, not evidence
that Desktop does not support the Hook.

The real default installation has now succeeded as part of this Desktop review:
`install.ps1` exited 0, reported an enabled/trusted Hook, and passed its exact
Hook-command runtime check. Original configuration and user PATH checksums were
saved locally. Complete Desktop restart, file/directory recovery, danger-command
checks and real uninstall verification remain pending; installation alone is
not a Desktop E2E PASS.

The real Codex test uses a fixed model fixture served only on loopback. No
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
successful execution. Final JSONL results were fully parsed: 60 acceptance
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

Not tested: a separate Windows 10 machine, Desktop UI end to end, npm's
`codex.cmd` launcher, other command shells and arbitrary indirect deletion
programs. This tool is not an OS sandbox or a backup system.

Hook protocol sources: [official Hooks documentation](https://learn.chatgpt.com/docs/hooks),
[Codex 0.160.0 local Hook trust implementation](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/tui/src/hooks_rpc.rs).
