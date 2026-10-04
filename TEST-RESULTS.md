# Actual test results

Tested locally on **2026-10-04 (UTC+08:00)**. Windows build 22631 (23H2),
Codex CLI **0.160.0**, Git 2.55.0. Production code uses PowerShell and .NET only.

## Windows MVP environment and installation repairs — 2026-10-04

The final MVP verification passed **483/483 checks**, with zero skips. This
counts the 20 PowerShell suites below plus three cross-runtime checks and two
real-console code-page checks. Windows build 22631, non-administrator access,
Windows PowerShell **5.1.22621.5909**, PowerShell **7.6.5** and Codex CLI
**0.160.0** were used. Repeated verification is not counted twice.

| Suite | PowerShell 5.1 | PowerShell 7 |
| --- | --- | --- |
| Installation acceptance and rollback | 43/43 PASS | 43/43 PASS |
| Protection switch and configuration lifecycle | 27/27 PASS | 27/27 PASS |
| Storage faults and interrupted recovery | 19/19 PASS | 19/19 PASS |
| Runtime preflight | 9/9 PASS | 9/9 PASS |
| Hook registration, duplicate reports and conflicts | 44/44 PASS | 44/44 PASS |
| Shell selection and deletion wrappers | 44/44 PASS | 44/44 PASS |
| Windows filesystem checks | 6/6 PASS | 6/6 PASS |
| Hook watchdog and response validation | 39/39 PASS | 39/39 PASS |
| Installation filesystem preflight and partial-copy failure | 5/5 PASS | 5/5 PASS |
| Positive Hook health verification | 3/3 PASS | 3/3 PASS |

The complete reports and JSONL evidence were parsed independently: 478 PASS
cases, 26 parsed files, zero parsing errors, and 19/19 frozen source hashes
matched. Review found an acceptance assertion checking `history.jsonl` instead
of the real `history.json`. After correcting that assertion, both complete
acceptance suites passed again, 86/86; their six evidence files parsed without
errors and all 19 final source hashes matched. Comparing the two runs confirmed
that only this test assertion changed; production code remained identical.

The installer now refuses orphaned registration, stale program files, malformed
or locked configuration, and concurrent installation/uninstall before writing.
Failed preparation cleans only its own files and preserves unexpected residuals.
Duplicate API reports are folded only when their key and metadata match exactly;
distinct or conflicting registrations retain a diagnostic with source and keys.
The original screenshot's exact two-registration state was not reproduced on
this machine; these cases were reproduced separately in isolated fixtures.

Ambiguous aliases without shell information are denied. An explicit PowerShell
shell or a `-NoProfile -Command` wrapper is required for automatic deletion
recovery. Wrappers with startup-directory arguments or unknown/dynamic flags are
denied before selecting targets; tests preserve same-named files in both
directories. POSIX, CMD and WSL commands use their own conservative checks.

The Hook has a 20-second monotonic budget inside the registered 30-second Codex
timeout. Watchdog faults emit structured denial. Positive health verification
requires the specific successful root-protection result; a generic fault denial
does not establish ON. Tests use a shortened 2.5-second budget for timeout
fixtures and include production-module ON/OFF behavior. Retained failures exposed
PS5's additional inherited stdout handle, which kept Codex's pipe open after
the parent exited. The corrected PS5 worker inherits only its three explicit
pipe handles. PS5/PS7 descendant tests closed the SDK pipe in about 2.8 seconds;
separate real-module checks passed 12/12 across PS5 x64, PS5 x86 and PS7.

Cross-runtime recovery passed 3/3, with binary bytes and empty directories
restored in both directions and unreadable sources refused. Real-console
code-page tests passed 2/2 under 936 and 65001; Chinese, spaces, apostrophes and
emoji names retained exact binary content. Isolated installations were removed.

The local installed program was backed up and repaired after verification.
Eleven source-controlled installed files matched their source hashes. The actual
`Install SafeDelete.cmd` invocation returned exit 0 and its success marker, with
no error lines. An installed-command smoke check moved and restored two targets,
including binary data and an empty directory. There is exactly one registered
SafeDelete Hook. Protection is **ON**; Codex configuration/hooks and User PATH
remained unchanged throughout these verified operations.

These results establish the tested Windows MVP boundary. Windows 7/8 and
pre-1809 Windows 10 are refused; Linux/macOS are not implemented. Eight runtime
cases per suite simulate version/platform boundaries rather than running those
systems. Filesystem suites include two native directory queries (ordinary and
over-300-character paths) and four injected refusal cases. They do not establish
complete long-path delete/undo or real case-sensitive-directory support. Network
shares, FAT/exFAT, other Codex versions, independent Windows 10 machines and other
antivirus environments remain unverified. The full Desktop GUI exit/restart
sequence was not repeated for this batch; earlier results below are historical.

Local evidence (ignored by Git):

- Full run and independent audit: `tests/.work/mvp-final-20261004-205622-36f045c5/{verification,audit}.json`
- Corrected acceptance rerun: `tests/.work/mvp-acceptance-20261004-210415-26108123/{verification,audit}.json`
- Cross-runtime: `tests/.work/mvp-cross-runtime/compatibility-20261004-130137-0bae6c9c/report.json`
- Code pages: `tests/.work/codepage-compatibility-20261004-210209-96576143/report.json`
- Local repair backup and source proof: `work/local-install-update-20261004-210507/`
- Actual installer CMD: `tests/.work/install-click-20261004-210513/report.json`
- Installed delete/undo: `tests/.work/installed-mvp-smoke-20261004-210522/report.json`
- Aggregate: `work/mvp-completion-20261004.json`
- Retained failed runs: `tests/.work/mvp-final-20261004-203145-592c140d/verification.json` (454/458) and `tests/.work/mvp-final-20261004-204144-8687ed90/verification.json` (77/78).

Reproduce with the existing acceptance/protection/storage/compatibility/code-page
scripts and `tests/runtime-compatibility.ps1`, `tests/hook-registration.ps1`,
`tests/shell-compatibility.ps1`, `tests/windows-filesystem.ps1`,
`tests/hook-watchdog.ps1`, `tests/install-preflight.ps1` and
`tests/hook-selfcheck.ps1`. Installation suites use isolated Codex homes and
`-NoPathUpdate`; code-page verification requires a real Windows console.

## Release repairs and compatibility — 2026-10-04

The final repair run passed **171/171 checks**, with no skips. It used Windows
build 22631, a non-administrator process, Windows PowerShell **5.1.22621.5909**
and PowerShell **7.6.5**.

| Verification | Result |
| --- | --- |
| Acceptance, including rollback cleanup and real Hook timeout/reinstall | 37/37 PASS in each PowerShell version |
| Pause/resume and installation lifecycle | 27/27 PASS in each version |
| Storage faults, interrupted journal writes and recovery conflicts | 19/19 PASS in each version |
| PS 5.1 → 7 and 7 → 5.1 recovery; unreadable-file refusal | 3/3 PASS |
| Installed `.cmd` delete/undo under Windows code pages 936 and 65001 | 2/2 PASS |

Rollback cleanup now removes only the installation files. Existing and newly
created Codex configuration, hooks and PATH changes made after rollback remain
untouched. A failed rollback state write leaves an incomplete state that refuses
uninstallation. A real 10-second Hook verification timeout was followed by
cleanup, reinstallation and exact configuration restoration in both shells.

Zero-move records are cancelled without claiming a restore and do not block an
older deletion's undo. A final journal write failure can finish on retry only
after full file/tree content verification. Tests reject same-length content
replacement, removed empty directories, missing active payloads, injected
sensitive paths and invalid history. Legacy interrupted records without enough
content evidence remain preserved for manual inspection.

The first repair run retained a **FAIL**: PowerShell 7's installed `.cmd` →
Windows PowerShell child could not load `Get-FileHash`. File fingerprints now use
.NET streaming SHA256. Both installed-command paths passed the complete rerun.
Cross-runtime and code-page tests also checked restored binary bytes, empty
directories, and names containing Chinese, spaces, apostrophes and an emoji.
An unreadable source file left the original, older history and older trash intact.

The four final JSONL files were completely parsed: **128 PASS rows**, zero parse
errors. All 43 cases in the four storage/compatibility reports were also parsed
and passed. **43 source-hash comparisons** matched the current code. The installed
global protection was restored to **ON**; global Codex configuration/hooks and
User PATH hashes/values remained unchanged.

Local evidence (ignored by Git):

- Final six-suite run: `tests/.work/release-fixes-20261004-191258-67497d65/verification.json`
- Earlier run with the retained module-loading failure: `tests/.work/release-fixes-20261004-190411-43f107d5/verification.json`
- Cross-runtime compatibility: `tests/.work/release-fix-compatibility/compatibility-20261004-111351-fe7623d3/report.json`
- Code pages: `tests/.work/codepage-compatibility-20261004-191557-b60cd8c3/report.json`

Reproducible scripts are `tests/acceptance.ps1`, `tests/protection.ps1`,
`tests/storage-faults.ps1`, `tests/compatibility.ps1` and `tests/codepages.ps1`.
Run code-page tests from a separate Windows console so `chcp` has a real console.
All installers in these tests use isolated Codex homes and `-NoPathUpdate`.
This repair batch did not repeat the full Desktop GUI restart sequence; the
earlier Desktop results below remain historical. A separate Windows 10 machine,
other Codex versions and other antivirus products have not been verified.

## Pause and resume protection

The new installation-wide `protection-state.json` switch is read by the Hook
on every invocation. Switching does not rewrite Codex configuration or PATH.
Deletion planning, storage, recovery and Hook trust implementations are unchanged.

| Actual check | Result |
| --- | --- |
| Strict off/on/status suite, Windows PowerShell 5.1.22621.5909 | 27/27 PASS |
| Strict off/on/status suite, PowerShell 7.6.5 | 27/27 PASS |
| Real Codex CLI 0.160.0, installer run from each PowerShell version | PASS: 12 actions and 4 native scenarios per run |
| Existing acceptance suite on the current scripts | PS5.1 33/33 PASS; PS7 33/33 PASS |
| Explorer mouse double-click Pause / Resume, including success windows | PASS |
| Desktop OFF restart and ON restart | PASS: full exit/reopen verified; actual deletion behavior matches each state |
| Earlier recovery records after pause/resume | PASS: exact trash/history preserved; old and new files restored by two undo calls |
| Real default uninstall after pause/resume | PASS: double-click; original configuration bytes and User PATH restored; installed files removed |

The final default installation and Desktop checks passed after the operator
manually allowed 360 warnings. Two earlier Explorer installation attempts failed
the Hook self-check; a screenshot confirms 360 blocked `hooks/pre-tool-use.ps1`.
A third attempt timed out while 360 warned about the Windows console host.
All checked source/install files remained present with matching copied hashes.
Each failed attempt's configuration/PATH rollback and residual-file cleanup
were verified before retrying. These failures remain recorded as FAIL.

Only the existing self-check command transport was changed from encoded text
to a readable PowerShell command; missing or malformed Hook output now produces
a clear installation error. No antivirus settings or exclusions were changed
by the tool. Default compatibility with 360 or other antivirus products is
not proven, and zero false positives are not promised.

The final real Desktop run used package **26.930.3930.0**, the default user
installation and a project path containing spaces and Chinese characters.
The operator fully exited and reopened Desktop three times: initial ON,
paused OFF, and resumed ON. Prior process identities were checked after each
restart. Actual ON deletes before pause and after resume were intercepted and
stored with exact original bytes. During OFF, an actual synthetic deletion
ran normally, created no recovery record, and left all previous trash/history
bytes unchanged. Pause and Resume preserved Hook configuration, installed files
and User PATH. Two actual `safedelete undo` calls restored both saved files.
The real double-click uninstaller restored the original configuration and PATH
without a manual merge and preserved history.

The old Desktop session did not intercept one synthetic delete before the
required initial reopen; that check is FAIL, and its fixture was recreated.
The first Resume mouse attempt also failed to launch its terminal and remained
OFF; the observed retry launched normally and passed all state/window checks.
Neither failed attempt is counted as PASS. No user files were selected.

The isolated suites check initial ON, repeated off/on, status from a child
directory with spaces and Chinese characters, missing or damaged state,
disabled/untrusted/changed Hooks, preservation of later unrelated configuration,
and repeated installation while OFF. Existing list/restore/undo work while OFF;
undo also restores records saved before pause after resuming. Isolated uninstall
preserves history and restores configuration. These runs use `-NoPathUpdate`;
default installation and User PATH restoration require the separate Desktop run.

The real CLI tests use only synthetic files and a fixed loopback model fixture.
OFF executes the original delete without creating a recovery record; ON again
replaces deletion with recoverable storage. A malformed pause flag is blocked
by the native Hook, with zero command-execution events. Two undo calls restore
both pre-pause and post-resume records. All 48 JSONL events were fully parsed,
with zero parse errors; running-source hashes match the tested scripts.

An initial real CLI run **failed**: the new state-read error used exit 2, which
the Windows shell wrapper normalized to exit 1, allowing the synthetic deletion.
An audit also rejected four earlier unit results whose assertions accepted any
nonzero exit. The minimum fix affects only the new pause-state error branch:
it returns explicit deny JSON with exit 0. The strict suites and real CLI tests
above were rerun after this fix and again after the self-check transport change.
The original deletion rules were not changed. Across the final four PowerShell
suites, all 120 records passed with zero parse errors; all 40 runtime-source
hash comparisons matched.
Official behavior: [PowerShell command wrapping](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/shell.rs#L22)
and [PreToolUse result handling](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/hooks/src/events/pre_tool_use.rs#L193).

Seven earlier CLI attempts remain recorded as FAIL: one argument-contract error,
three test-helper encoding/initialization failures, the bad-state failure above,
one documentation snapshot drift, and one assertion mistaking a blocked command's
echo for execution. The final two CLI runs pass; those failures are not counted
as successful tests. No user files were selected.

Local evidence is ignored by Git:
`tests/.work/pause-cli-readable-summary.json`,
`tests/.work/protection-final-report-plain-command.json`,
`tests/.work/codex-hook-20261004-161955-3b790113/`,
`tests/.work/codex-hook-20261004-162040-057fdad1/`, and
`work/pause-desktop/desktop-final-summary.json` (18 checked PASS records and
9 matching runtime-source hashes). Private configuration/PATH snapshots stay local.

The sections below record the previously verified baseline releases.

## Double-click installation

The two new CMD files only launch the existing PowerShell scripts and display
their exit result. They always use Windows PowerShell 5.1, including when
called from a PowerShell 7 console. Direct PowerShell 7 installation was
tested separately. No deletion, storage, recovery, Hook or uninstall logic
changed during this installation-experience update.

| Actual check | Result |
| --- | --- |
| Extracted source paths containing spaces, Chinese characters and `!` | PASS |
| Install/uninstall CMD called from Windows PowerShell 5.1 and PowerShell 7 | PASS |
| Direct installer under PS5.1 and PS7 with Codex absent from PATH | PASS: Desktop's local binary found; original process PATH recorded |
| Explorer mouse double-click of `Install SafeDelete.cmd` | PASS: real default user installation and retained success window |
| Newly installed Hook in the running Codex Desktop | PASS: actual `Remove-Item` rewritten; exact fixture bytes preserved in trash |
| `safedelete undo` through the installed User PATH | PASS: original location and exact bytes restored |
| Explorer mouse double-click of `Uninstall SafeDelete.cmd` | PASS: real default uninstallation and retained success window |
| Original Codex configuration and User PATH after uninstall | PASS: byte-exact/checksum match; installation directory absent |
| Missing scripts and configuration conflicts | PASS: nonzero exit, failure message, no false success; conflicts preserved |
| Saved execution policies | PASS: unchanged |

The Explorer checks used actual mouse down/up pairs on the observed CMD list
items, within the Windows double-click interval. They were not replaced with
`cmd /c`, ShellExecute or UIAutomation Invoke. Success text was read from the
new terminal windows. Codex Desktop was never killed or forcibly restarted.
The existing Desktop session loaded the installed Hook for the actual deletion;
the user-facing instruction still says to reopen Codex and the terminal once.

The first real Explorer attempt **failed** because Explorer lacked the Codex
agent's injected PATH. Its failure window stayed open. The minimum fix is
only in `install.ps1`: if Codex is missing from PATH, locate a regular local
Desktop `codex.exe` in its existing binary folder, reject linked paths, and
temporarily add its directory to the installer process PATH. User PATH still
receives only SafeDelete. Both PowerShell versions and real Explorer were
tested after the fix.

Two rapid repeated-install attempts also hit the existing local app-server's
20-second initialization timeout. Both reported failure and rolled back;
independent repeats passed. These failed attempts remain in local evidence
and are not counted as PASS. Hook startup or protection code was not changed.

Full evidence is local and ignored by Git in `work/launcher-final/`:
`final-automated-report.json`, `fallback-report.json`, mouse double-click
reports, installation/uninstallation window checks and Desktop delete/undo
reports. Original configuration snapshots and PATH values are private local
evidence only. Earlier failed-attempt logs are preserved there as well.

After the installer lookup change, the complete existing acceptance suites
were run again on the delivered scripts: PS5.1 **33/33 PASS** and PS7
**33/33 PASS**, including actual npm execution and uninstall conflicts.

## Existing protection and installation suites

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
- `tests/.work/20261004-151300-5-fb1724a6/results.jsonl` and `summary.json` (final launcher-update regression, 33 cases)
- `tests/.work/20261004-151302-7-bbe3499d/results.jsonl` and `summary.json` (final launcher-update regression, 33 cases)
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
