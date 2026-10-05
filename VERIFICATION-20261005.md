# Release candidate verification — 2026-10-05 (UTC+08:00)

This candidate is ready for a Windows local MVP / preview release within the
tested environment below. The locally retained source package's
`SOURCE-MANIFEST.json` records every included file's SHA256. At testing time,
its source baseline was `586a487ef0732a115206d1019ad8a38118ba1fb4`, with the
configuration ownership repair and regression tests included as frozen
workspace changes.

Those repair changes were subsequently committed as
`7de475e420080033ead50d717a3cedbd5ae11fd8`; later README revisions are recorded
in `f3f98988fd33ad2f6942c3bbbb4789542d1c28b9`. This report retains the
original pre-commit test provenance.

## Tested environment and checks

- Windows 11 build 22631; Windows PowerShell 5.1.22621.5909 and PowerShell 7.6.5.
- Codex Desktop 26.930.3930.0 and native Codex CLI 0.160.0.
- Trust protocol: 60/60 per runtime; protection and uninstall: 27/27 per runtime;
  installation preflight: 5/5 per runtime; Hook self-check: 3/3 per runtime.
- Full installation/migration regression: 43/43 per runtime, 86/86 overall,
  with both processes exiting 0. The 14 targeted concurrency/recovery cases per
  runtime are a subset of these 43 cases.
- Cold native CLI integration: both installation/control runtimes passed;
  tools and Hook were real, with a deterministic local loopback model service.
- Actual original-version uninstall, repaired-version install, repaired-version
  default uninstall and final reinstall all exited 0 with empty stderr.
- Installed runtime source: 11/11 files match the repaired workspace. SDK
  registration identifies one enabled and trusted SafeDelete Hook.
- Actual Desktop deletion after the user-confirmed complete GUI restart was
  rewritten into recoverable storage. Explicit-ID restore preserved a 256-byte
  binary file, special-character names and a directory tree with two levels and
  no files. All 27
  pre-existing history records were preserved; the new record was restored.
- Actual Desktop patch deletion was blocked by SafeDelete; the probe remained
  unchanged. Final protection is ON and command resolution selects the shared
  user-profile installation.

## Configuration repair and installation requirement

Trust previews the intended SDK edits on saved configuration bytes in a
temporary local `CODEX_HOME`, then validates real configuration byte hashes
before writing and after write/reload. The expected output hash is published
before writing, so a failed confirmation can still roll back known SDK output.
Unrecognized concurrent bytes are preserved for inspection. Normal temporary
configuration copies are removed after the preview SDK process is stopped.

Reopen Codex and terminals after installation or upgrade, as the README requires.
The first synthetic delete in the still-running conversation after reinstall
did not create a recovery record. Its backed-up synthetic data was restored.
After the user-confirmed complete GUI restart, the same route intercepted
deletion and passed recovery. Automatic hot reload during an active conversation
is not certified.

## Supported release scope

This is local Windows deletion protection for the tool and command forms
documented in the README. The SDK's own file read/write window and arbitrary
cross-process races remain outside this repair's guarantee. The tests use
explicit failure/timeout injection; they do not simulate every real network
failure. Independent Windows 10 machines, other Codex versions, online-model
behavior and other/default antivirus settings still need separate validation.
Linux, macOS and Windows 7 remain outside this release's supported platforms.

The source package includes [the trust-concurrency test helper](tests/helpers/trust-concurrency.ps1),
required by the migration regression harness. Public checks are available in
[the test scripts](tests/); [TEST-RESULTS.md](TEST-RESULTS.md) describes their
results and scope.

Evidence paths under `work/` and `tests/.work/`, along with the locally retained
package manifest, are local-only records. Machine configuration backups, recovery
history, raw test logs and installation state are excluded from the public
repository and source package.
