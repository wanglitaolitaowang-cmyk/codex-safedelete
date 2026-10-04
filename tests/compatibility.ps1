# Isolated PowerShell compatibility checks; no Codex configuration or PATH writes.
[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $PSScriptRoot '.work' }
$project = Split-Path $PSScriptRoot -Parent
$storage = Join-Path $project 'src\Storage.ps1'
. $storage
$run = 'compatibility-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$evidence = [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $run))
$null = [IO.Directory]::CreateDirectory($evidence)
$results = New-Object 'System.Collections.Generic.List[object]'
$ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ps7 = $null
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $ps7 = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
} else {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { $ps7 = $command.Source }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-NativeFileHash {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Invoke-CompatibilityProcess {
    param([string]$Program, [string[]]$Arguments, [string]$Root, [string]$EvidencePath)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Program
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Cannot start compatibility child process.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw ('Compatibility child timed out: ' + $Program)
        }
        $result = [pscustomobject]@{
            program = $Program; arguments = $Arguments; exitCode = $process.ExitCode
            stdout = $stdoutTask.Result; stderr = $stderrTask.Result
        }
        [IO.File]::WriteAllText($EvidencePath, ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Assert-True ($result.exitCode -eq 0) ("Child failed (exit $($result.exitCode)); see $EvidencePath")
        try { return ($result.stdout | ConvertFrom-Json -ErrorAction Stop) }
        catch { throw ('Child returned invalid JSON; see ' + $EvidencePath) }
    } finally { $process.Dispose() }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $details = & $Body
        $results.Add([pscustomobject]@{ name = $Name; result = 'PASS'; error = $null; details = $details })
    } catch {
        $results.Add([pscustomobject]@{ name = $Name; result = 'FAIL'; error = $_.Exception.Message; details = $null })
    }
}

$worker = Join-Path $evidence 'worker.ps1'
$workerText = @'
param([string]$Action, [string]$StoragePath, [string]$Root, [string]$PayloadPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. $StoragePath
if ($Action -eq 'delete') {
    $record = Move-SafeDeleteItems -ProjectRoot $Root -Paths @($PayloadPath) -Command 'compatibility fixture'
    $restoreFingerprint = $null
} elseif ($Action -eq 'restore') {
    $record = Restore-SafeDeleteRecord -ProjectRoot $Root
    $restoreFingerprint = $record.items[0].restore_fingerprint
} else { throw 'Unknown compatibility action.' }
[pscustomobject]@{
    runtime = $PSVersionTable.PSVersion.ToString(); id = $record.id; status = $record.status
    sourceFingerprint = $record.items[0].source_fingerprint
    restoreFingerprint = $restoreFingerprint
} | ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText($worker, $workerText, (New-Object Text.UTF8Encoding($false)))

foreach ($direction in @(
    [pscustomobject]@{ name = 'PowerShell 5.1 delete to PowerShell 7 restore'; folder = 'PS5-to-PS7'; deleting = $ps5; restoring = $ps7; deleteMajor = 5; restoreMajor = 7 },
    [pscustomobject]@{ name = 'PowerShell 7 delete to PowerShell 5.1 restore'; folder = 'PS7-to-PS5'; deleting = $ps7; restoring = $ps5; deleteMajor = 7; restoreMajor = 5 }
)) {
    Test-Case $direction.name {
        Assert-True ([IO.File]::Exists($direction.deleting) -and [IO.File]::Exists($direction.restoring)) 'Both Windows PowerShell 5.1 and PowerShell 7 are required.'
        $root = Join-Path $evidence $direction.folder
        $unicodeName = "space $([char]0x6D4B)$([char]0x8BD5)'s " + [char]::ConvertFromUtf32(0x1F680)
        $folder = Join-Path $root $unicodeName
        $empty = Join-Path $folder ('empty ' + $unicodeName)
        $file = Join-Path $folder ($unicodeName + '.bin')
        $null = [IO.Directory]::CreateDirectory($empty)
        $bytes = [byte[]]@(0, 1, 127, 128, 254, 255, 10, 13, 0, 255)
        [IO.File]::WriteAllBytes($file, $bytes)
        $common = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $worker, '-StoragePath', $storage, '-Root', $root, '-PayloadPath', $folder)
        $deleted = Invoke-CompatibilityProcess $direction.deleting ($common + @('-Action', 'delete')) $root (Join-Path $root 'delete.json')
        Assert-True (([version]$deleted.runtime).Major -eq $direction.deleteMajor -and $deleted.status -eq 'active' -and -not [IO.Directory]::Exists($folder)) 'The requested deleting runtime did not save the complete directory.'
        $restored = Invoke-CompatibilityProcess $direction.restoring ($common + @('-Action', 'restore')) $root (Join-Path $root 'restore.json')
        Assert-True (([version]$restored.runtime).Major -eq $direction.restoreMajor -and $restored.status -eq 'restored' -and $restored.id -eq $deleted.id) 'The requested restoring runtime did not restore the same record.'
        Assert-True ([IO.File]::Exists($file) -and [IO.Directory]::Exists($empty)) 'Unicode names or the empty directory were lost.'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($bytes)) 'Restored binary contents differ.'
        Assert-True ($deleted.sourceFingerprint -match '^[A-F0-9]{64}$' -and $restored.sourceFingerprint -ceq $deleted.sourceFingerprint -and $restored.restoreFingerprint -ceq $deleted.sourceFingerprint) 'Payload fingerprints differ between PowerShell runtimes.'
        [pscustomobject]@{
            delete_runtime = $deleted.runtime; restore_runtime = $restored.runtime
            source_fingerprint = $deleted.sourceFingerprint; restore_fingerprint = $restored.restoreFingerprint
            binary_bytes = $bytes.Length; empty_directory_preserved = $true; unicode_path = $folder
        }
    }
}

Test-Case 'unreadable source refuses deletion and preserves previous history and payload' {
    $root = Join-Path $evidence 'read-blocked'
    $null = [IO.Directory]::CreateDirectory($root)
    $old = Join-Path $root 'older.bin'; $blocked = Join-Path $root 'blocked.bin'
    [IO.File]::WriteAllBytes($old, [byte[]]@(0, 255, 17, 128))
    [IO.File]::WriteAllBytes($blocked, [byte[]]@(255, 0, 254, 1))
    $previous = Move-SafeDeleteItems $root @($old) 'compatibility older fixture'
    $historyPath = Join-Path $root '.codex-safedelete\history.json'
    $historyHash = Get-NativeFileHash $historyPath
    $oldHash = Get-NativeFileHash $previous.items[0].trash_path
    $blockedHash = Get-NativeFileHash $blocked
    $handle = [IO.File]::Open($blocked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $refused = $false
        try { $null = Move-SafeDeleteItems $root @($blocked) 'compatibility unreadable fixture' }
        catch { $refused = $true }
        Assert-True $refused 'Deletion of a source with no read-sharing unexpectedly succeeded.'
    } finally { $handle.Dispose() }
    Assert-True ([IO.File]::Exists($blocked) -and (Get-NativeFileHash $blocked) -ceq $blockedHash) 'The unreadable source changed.'
    Assert-True ((Get-NativeFileHash $historyPath) -ceq $historyHash) 'The failed fingerprint changed previous history.'
    Assert-True (-not [IO.File]::Exists($old) -and [IO.File]::Exists($previous.items[0].trash_path) -and (Get-NativeFileHash $previous.items[0].trash_path) -ceq $oldHash) 'The previous recoverable payload changed.'
    $history = @(Get-SafeDeleteHistory $root)
    Assert-True ($history.Count -eq 1 -and $history[0].id -eq $previous.id -and $history[0].status -eq 'active') 'A refused read added or altered a deletion record.'
    [pscustomobject]@{ original_preserved = $true; prior_history_preserved = $true; prior_trash_preserved = $true }
}

$passed = @($results | Where-Object { $_.result -eq 'PASS' }).Count
$failed = $results.Count - $passed
$reportPath = Join-Path $evidence 'report.json'
$report = [pscustomobject]@{
    result = $(if ($failed -eq 0) { 'PASS' } else { 'FAIL' })
    runtime = $PSVersionTable.PSVersion.ToString(); tested_at = [DateTime]::UtcNow.ToString('o')
    total = $results.Count; passed = $passed; failed = $failed
    storage_sha256 = Get-NativeFileHash $storage
    tests = @($results.ToArray()); fixtures = $evidence
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ result = $report.result; runtime = $report.runtime; total = $report.total; passed = $passed; failed = $failed; report = $reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
