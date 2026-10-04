# Real filesystem faults in isolated fixtures; no Codex/global configuration changes.
[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $PSScriptRoot '.work' }
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\Storage.ps1')
$run = 'storage-faults-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$evidence = [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $run))
$null = [IO.Directory]::CreateDirectory($evidence)
$results = New-Object 'System.Collections.Generic.List[object]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function New-Fixture {
    param([string]$Name)
    $path = Join-Path $evidence $Name
    $null = [IO.Directory]::CreateDirectory($path)
    return $path
}
function Expect-Deny {
    param([scriptblock]$Body)
    $denied = $false
    try { & $Body | Out-Null }
    catch { if ($_.Exception.Message -like 'DENY:*') { $denied = $true } else { throw } }
    Assert-True $denied 'Expected a deterministic DENY.'
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body | Out-Null
        $results.Add([pscustomobject]@{ name = $Name; result = 'PASS'; error = $null })
    } catch {
        $results.Add([pscustomobject]@{ name = $Name; result = 'FAIL'; error = $_.Exception.Message })
    }
}

function Invoke-FinalJournalFault {
    param([string]$Root, [object]$Record)
    $nativeMove = ${function:Move-SDItem}
    $fault = [pscustomobject]@{ handle = $null }
    # Perform the real filesystem renames. Only when the final payload reaches
    # its original path do we lock the journal against Replace/FileShare.Delete.
    function Move-SDItem {
        param([string]$Source, [string]$Destination, [string]$Type)
        & $nativeMove $Source $Destination $Type
        if (@($Record.items | Where-Object { Test-Path -LiteralPath $_.trash_path }).Count -eq 0) {
            $fault.handle = [IO.File]::Open((Join-Path $Root '.codex-safedelete\history.json'),
                [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        }
    }
    try {
        $failed = $false
        try { $null = Restore-SafeDeleteRecord $Root $Record.id } catch { $failed = $true }
        Assert-True $failed 'The final journal write unexpectedly succeeded.'
        Assert-True ($null -ne $fault.handle) 'The fault was not injected after all real moves.'
        Assert-True (@(Get-SafeDeleteHistory $Root | Where-Object { $_.id -eq $Record.id })[0].status -eq 'restoring') 'The failed final write was not durable as restoring.'
        foreach ($item in $Record.items) {
            Assert-True ((Test-Path -LiteralPath $item.original_path) -and -not (Test-Path -LiteralPath $item.trash_path)) 'The fault did not occur after every payload was restored.'
        }
    } finally { if ($null -ne $fault.handle) { $fault.handle.Dispose() } }
}

Test-Case 'pending move failure is recoverable' {
    $root = New-Fixture 'pending'
    $a = Join-Path $root 'a.txt'; $b = Join-Path $root 'b.txt'
    [IO.File]::WriteAllText($a, 'first'); [IO.File]::WriteAllText($b, 'second')
    # No FILE_SHARE_DELETE: the second rename genuinely fails on Windows.
    $handle = [IO.File]::Open($b, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { $null = Move-SafeDeleteItems $root @($a, $b) 'rm a.txt b.txt' }
        catch { if ($_.Exception.Message -like 'SafeDelete move interrupted*') { $failed = $true } else { throw } }
        Assert-True $failed 'The locked second file did not cause a move failure.'
    } finally { $handle.Dispose() }
    $history = @(Get-SafeDeleteHistory $root)
    Assert-True ($history.Count -eq 1 -and $history[0].status -eq 'pending') 'Pending journal was not durable.'
    Assert-True (-not (Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b)) 'Expected only the first file to move.'
    $null = Restore-SafeDeleteRecord $root
    Assert-True ([IO.File]::ReadAllText($a) -eq 'first' -and [IO.File]::ReadAllText($b) -eq 'second') 'Pending undo lost data.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restored') 'Undo did not complete its journal.'
}

Test-Case 'interrupted restore can be retried' {
    $root = New-Fixture 'restore-interruption'
    $a = Join-Path $root 'a.txt'; $b = Join-Path $root 'b.txt'
    [IO.File]::WriteAllText($a, 'first'); [IO.File]::WriteAllText($b, 'second')
    $record = Move-SafeDeleteItems $root @($a, $b) 'del a.txt b.txt'
    $handle = [IO.File]::Open($record.items[1].trash_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { $null = Restore-SafeDeleteRecord $root $record.id } catch { $failed = $true }
        Assert-True $failed 'The locked second trash file did not cause a restore failure.'
        Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restoring') 'Interrupted restore did not journal its state.'
        Assert-True ((Test-Path -LiteralPath $a) -and -not (Test-Path -LiteralPath $b)) 'Expected only the first file to restore.'
        Assert-True (Test-Path -LiteralPath $record.items[1].trash_path) 'Unrestored data was lost.'
    } finally { $handle.Dispose() }
    $null = Restore-SafeDeleteRecord $root $record.id
    Assert-True ([IO.File]::ReadAllText($a) -eq 'first' -and [IO.File]::ReadAllText($b) -eq 'second') 'Restore retry lost data.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restored') 'Restore retry did not complete.'
}

Test-Case 'tampered trash_path is denied' {
    $root = New-Fixture 'tampered-history'
    $original = Join-Path $root 'payload.txt'; $other = Join-Path $root 'keep.txt'
    [IO.File]::WriteAllText($original, 'payload'); [IO.File]::WriteAllText($other, 'keep')
    $record = Move-SafeDeleteItems $root @($original) 'rm payload.txt'
    $history = @(Get-SafeDeleteHistory $root)
    $history[0].items[0].trash_path = $other
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    Expect-Deny { Restore-SafeDeleteRecord $root $record.id }
    Assert-True ([IO.File]::ReadAllText($other) -eq 'keep') 'Tampered history moved the unrelated file.'
    Assert-True (Test-Path -LiteralPath $record.items[0].trash_path) 'Original recoverable payload was lost.'
}

foreach ($part in @('history.json', 'store.lock')) {
    # A junction needs no symbolic-link privilege and has the same ReparsePoint flag.
    Test-Case ($part + ' reparse point is denied') {
        $root = New-Fixture ('link-' + $part)
        $store = Initialize-SafeDeleteStore $root
        $target = Join-Path $root 'link-target'
        $null = [IO.Directory]::CreateDirectory($target)
        $sentinel = Join-Path $target 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'keep')
        $link = Join-Path $store $part
        $null = New-Item -ItemType Junction -Path $link -Target $target
        try {
            Expect-Deny { Get-SafeDeleteHistory $root }
            Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'keep') 'Metadata link target changed.'
        } finally { [IO.Directory]::Delete($link) }
    }
}

Test-Case 'first move failure cancels without claiming a restore' {
    $root = New-Fixture 'zero-payload'
    $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($file, 'payload')
    $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { $null = Move-SafeDeleteItems $root @($file) 'rm payload.txt' }
        catch { if ($_.Exception.Message -like 'SafeDelete move interrupted*') { $failed = $true } else { throw } }
        Assert-True $failed 'The locked first file did not interrupt its move.'
    } finally { $handle.Dispose() }
    $history = @(Get-SafeDeleteHistory $root)
    Assert-True ($history.Count -eq 1 -and $history[0].status -eq 'pending') 'The zero-move journal was not pending.'
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root $history[0].id }
    catch { if ($_.Exception.Message -like 'Record cancelled; no files were restored*') { $failed = $true } else { throw } }
    Assert-True $failed 'An empty recovery incorrectly reported success.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'payload') 'The original file changed.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'cancelled') 'A verified zero-move record was not cancelled.'
}

Test-Case 'undo skips a cancelled zero-move record and restores older data' {
    $root = New-Fixture 'undo-after-zero-move'
    $old = Join-Path $root 'older.txt'; $new = Join-Path $root 'newer.txt'
    [IO.File]::WriteAllText($old, 'older'); [IO.File]::WriteAllText($new, 'newer')
    $previous = Move-SafeDeleteItems $root @($old) 'rm older.txt'
    $handle = [IO.File]::Open($new, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        try { $null = Move-SafeDeleteItems $root @($new) 'rm newer.txt'; throw 'The first move unexpectedly succeeded.' }
        catch { if ($_.Exception.Message -notlike 'SafeDelete move interrupted*') { throw } }
    } finally { $handle.Dispose() }
    $restored = Restore-SafeDeleteRecord $root
    Assert-True ($restored.id -eq $previous.id) 'Undo did not reach the older recoverable record.'
    Assert-True ([IO.File]::ReadAllText($old) -eq 'older' -and [IO.File]::ReadAllText($new) -eq 'newer') 'Undo changed or lost original contents.'
    $history = @(Get-SafeDeleteHistory $root)
    Assert-True ($history[0].status -eq 'restored' -and $history[1].status -eq 'cancelled') 'Undo journal confused cancelled and restored records.'
}

Test-Case 'pending original replacement prevents cancellation and older undo' {
    $root = New-Fixture 'pending-replacement'
    $old = Join-Path $root 'older.txt'; $file = Join-Path $root 'pending.txt'
    [IO.File]::WriteAllText($old, 'older'); [IO.File]::WriteAllText($file, 'before')
    $previous = Move-SafeDeleteItems $root @($old) 'rm older.txt'
    $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        try { $null = Move-SafeDeleteItems $root @($file) 'rm pending.txt'; throw 'The first move unexpectedly succeeded.' }
        catch { if ($_.Exception.Message -notlike 'SafeDelete move interrupted*') { throw } }
    } finally { $handle.Dispose() }
    [IO.File]::WriteAllText($file, 'after!')
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root }
    catch { if ($_.Exception.Message -like 'Restore conflict*') { $failed = $true } else { throw } }
    Assert-True $failed 'A replacement original was treated as an untouched pending payload.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'after!' -and (Test-Path -LiteralPath $previous.items[0].trash_path)) 'Conflict overwrote the replacement or silently undid the older record.'
    Assert-True (@(Get-SafeDeleteHistory $root)[1].status -eq 'pending') 'Conflicted pending record was cancelled.'
}

Test-Case 'final journal failure retries after all file and directory moves' {
    $root = New-Fixture 'final-journal'
    $file = Join-Path $root 'payload.txt'; $folder = Join-Path $root 'folder'
    [IO.File]::WriteAllText($file, 'payload')
    $null = [IO.Directory]::CreateDirectory((Join-Path $folder 'empty'))
    [IO.File]::WriteAllText((Join-Path $folder 'child.txt'), 'child')
    $record = Move-SafeDeleteItems $root @($file, $folder) 'rm payload.txt folder'
    Invoke-FinalJournalFault $root $record
    $restored = Restore-SafeDeleteRecord $root $record.id
    Assert-True ($restored.status -eq 'restored') 'Retry failed to finish the terminal journal.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'payload' -and [IO.File]::ReadAllText((Join-Path $folder 'child.txt')) -eq 'child' -and [IO.Directory]::Exists((Join-Path $folder 'empty'))) 'Retry changed restored file or directory contents.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restored') 'Final retry was not persisted.'
}

Test-Case 'final journal retry rejects changed same-length file contents' {
    $root = New-Fixture 'final-journal-replacement'
    $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($file, 'before')
    $record = Move-SafeDeleteItems $root @($file) 'rm payload.txt'
    Invoke-FinalJournalFault $root $record
    [IO.File]::WriteAllText($file, 'after!')
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root $record.id }
    catch { if ($_.Exception.Message -like 'Restore conflict*') { $failed = $true } else { throw } }
    Assert-True $failed 'Retry trusted a same-length replacement file.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'after!' -and @(Get-SafeDeleteHistory $root)[0].status -eq 'restoring') 'Retry overwrote the replacement or claimed completion.'
}

Test-Case 'final journal retry detects a removed empty directory' {
    $root = New-Fixture 'final-journal-empty-directory'
    $folder = Join-Path $root 'folder'; $empty = Join-Path $folder 'empty'
    $null = [IO.Directory]::CreateDirectory($empty)
    $record = Move-SafeDeleteItems $root @($folder) 'rm folder'
    Invoke-FinalJournalFault $root $record
    [IO.Directory]::Delete($empty)
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root $record.id }
    catch { if ($_.Exception.Message -like 'Restore conflict*') { $failed = $true } else { throw } }
    Assert-True $failed 'An incomplete directory tree was treated as completely restored.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restoring') 'The incomplete directory tree was marked restored.'
}

Test-Case 'active missing payload remains an error even with an original placeholder' {
    $root = New-Fixture 'active-missing-payload'
    $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($file, 'payload')
    $record = Move-SafeDeleteItems $root @($file) 'rm payload.txt'
    [IO.File]::Delete($record.items[0].trash_path)
    [IO.File]::WriteAllText($file, 'placeholder')
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root }
    catch { if ($_.Exception.Message -like 'Missing recoverable payload*') { $failed = $true } else { throw } }
    Assert-True $failed 'A missing active payload was silently skipped.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'placeholder' -and @(Get-SafeDeleteHistory $root)[0].status -eq 'active') 'Missing payload was reported restored or its placeholder changed.'
}

Test-Case 'legacy empty restoring is skipped without claiming completion' {
    $root = New-Fixture 'legacy-empty-restoring'
    $old = Join-Path $root 'older.txt'; $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($old, 'older'); [IO.File]::WriteAllText($file, 'payload')
    $previous = Move-SafeDeleteItems $root @($old) 'rm older.txt'
    $record = Move-SafeDeleteItems $root @($file) 'rm payload.txt'
    Invoke-FinalJournalFault $root $record
    $history = @(Get-SafeDeleteHistory $root)
    foreach ($item in $history[1].items) {
        $item.PSObject.Properties.Remove('source_fingerprint')
        $item.PSObject.Properties.Remove('restore_fingerprint')
    }
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root $record.id }
    catch { if ($_.Exception.Message -like 'No recoverable payload exists*') { $failed = $true } else { throw } }
    Assert-True $failed 'Legacy evidence-free record was claimed restored.'
    $restored = Restore-SafeDeleteRecord $root
    Assert-True ($restored.id -eq $previous.id -and [IO.File]::ReadAllText($old) -eq 'older') 'Legacy empty record blocked older undo.'
    Assert-True (@(Get-SafeDeleteHistory $root)[1].status -eq 'restoring') 'Skipping the legacy record claimed its completion.'
}

Test-Case 'legacy active payload still restores and gains recovery evidence' {
    $root = New-Fixture 'legacy-active'
    $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($file, 'payload')
    $record = Move-SafeDeleteItems $root @($file) 'rm payload.txt'
    $history = @(Get-SafeDeleteHistory $root)
    $history[0].items[0].PSObject.Properties.Remove('source_fingerprint')
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    $null = Restore-SafeDeleteRecord $root $record.id
    Assert-True ([IO.File]::ReadAllText($file) -eq 'payload' -and @(Get-SafeDeleteHistory $root)[0].status -eq 'restored') 'A legacy active payload failed to restore.'
}

Test-Case 'legacy partial restoring preserves existing originals and remaining trash' {
    $root = New-Fixture 'legacy-partial-restoring'
    $a = Join-Path $root 'a.txt'; $b = Join-Path $root 'b.txt'
    [IO.File]::WriteAllText($a, 'first'); [IO.File]::WriteAllText($b, 'second')
    $record = Move-SafeDeleteItems $root @($a, $b) 'rm a.txt b.txt'
    $handle = [IO.File]::Open($record.items[1].trash_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { $null = Restore-SafeDeleteRecord $root $record.id } catch { $failed = $true }
        Assert-True $failed 'The second restore move did not fail.'
    } finally { $handle.Dispose() }
    $history = @(Get-SafeDeleteHistory $root)
    foreach ($item in $history[0].items) {
        $item.PSObject.Properties.Remove('source_fingerprint')
        $item.PSObject.Properties.Remove('restore_fingerprint')
    }
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root $record.id }
    catch { if ($_.Exception.Message -like 'Cannot verify previously restored payload; historical content evidence is missing*') { $failed = $true } else { throw } }
    Assert-True $failed 'An evidence-free partial restore claimed success.'
    Assert-True ([IO.File]::ReadAllText($a) -eq 'first' -and [IO.File]::ReadAllText($record.items[1].trash_path) -eq 'second' -and -not (Test-Path -LiteralPath $b)) 'Legacy partial restore changed existing originals or remaining trash.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'restoring') 'Legacy partial restore changed its durable status.'
}

Test-Case 'empty pending history is validated before skipping to older undo' {
    $root = New-Fixture 'empty-pending-tampered-path'
    $old = Join-Path $root 'older.txt'; $file = Join-Path $root 'pending.txt'
    [IO.File]::WriteAllText($old, 'older'); [IO.File]::WriteAllText($file, 'pending')
    $previous = Move-SafeDeleteItems $root @($old) 'rm older.txt'
    $handle = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        try { $null = Move-SafeDeleteItems $root @($file) 'rm pending.txt'; throw 'The first move unexpectedly succeeded.' }
        catch { if ($_.Exception.Message -notlike 'SafeDelete move interrupted*') { throw } }
    } finally { $handle.Dispose() }
    $history = @(Get-SafeDeleteHistory $root)
    $history[1].items[0].trash_path = Join-Path $root 'unrelated-missing.txt'
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    Expect-Deny { Restore-SafeDeleteRecord $root }
    Assert-True ([IO.File]::ReadAllText($file) -eq 'pending' -and (Test-Path -LiteralPath $previous.items[0].trash_path)) 'A malformed empty record was skipped before safety checks.'
}

Test-Case 'final journal retry rejects protected descendants in original tree' {
    $root = New-Fixture 'final-journal-protected-tree'
    $folder = Join-Path $root 'folder'
    $null = [IO.Directory]::CreateDirectory($folder)
    [IO.File]::WriteAllText((Join-Path $folder 'safe.txt'), 'safe')
    $record = Move-SafeDeleteItems $root @($folder) 'rm folder'
    Invoke-FinalJournalFault $root $record
    [IO.File]::WriteAllText((Join-Path $folder '.env'), 'injected')
    Expect-Deny { Restore-SafeDeleteRecord $root $record.id }
    Assert-True ([IO.File]::ReadAllText((Join-Path $folder 'safe.txt')) -eq 'safe' -and @(Get-SafeDeleteHistory $root)[0].status -eq 'restoring') 'A protected original tree was claimed restored or changed.'
}

Test-Case 'junction target and parent are denied' {
    $root = New-Fixture 'source-junction'
    $target = Join-Path $root 'target'
    $null = [IO.Directory]::CreateDirectory($target)
    $sentinel = Join-Path $target 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'keep')
    $link = Join-Path $root 'junction'
    $null = New-Item -ItemType Junction -Path $link -Target $target
    try {
        Expect-Deny { Move-SafeDeleteItems $root @($link) 'rm -rf junction' }
        Expect-Deny { Move-SafeDeleteItems $root @(Join-Path $link 'keep.txt') 'rm junction/keep.txt' }
        Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'keep') 'Junction payload changed.'
    } finally { [IO.Directory]::Delete($link) }
}

Test-Case 'sensitive descendant injected into trash is denied' {
    $root = New-Fixture 'tampered-trash'
    $folder = Join-Path $root 'folder'
    $null = [IO.Directory]::CreateDirectory($folder)
    [IO.File]::WriteAllText((Join-Path $folder 'safe.txt'), 'safe')
    $record = Move-SafeDeleteItems $root @($folder) 'rm -rf folder'
    [IO.File]::WriteAllText((Join-Path $record.items[0].trash_path '.codex'), 'injected')
    Expect-Deny { Restore-SafeDeleteRecord $root $record.id }
    Assert-True (-not (Test-Path -LiteralPath $folder)) 'A tampered tree was restored.'
    Assert-True (Test-Path -LiteralPath (Join-Path $record.items[0].trash_path 'safe.txt')) 'The recoverable tree was lost.'
}

$passed = @($results | Where-Object { $_.result -eq 'PASS' }).Count
$failed = $results.Count - $passed
$reportPath = Join-Path $evidence 'report.json'
$report = [pscustomobject]@{
    result = $(if ($failed -eq 0) { 'PASS' } else { 'FAIL' })
    runtime = $PSVersionTable.PSVersion.ToString(); tested_at = [DateTime]::UtcNow.ToString('o')
    total = $results.Count; passed = $passed; failed = $failed
    storage_sha256 = (Get-FileHash -LiteralPath (Join-Path $project 'src\Storage.ps1') -Algorithm SHA256).Hash
    tests = @($results.ToArray()); fixtures = $evidence
}
[IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 5), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ result = $report.result; runtime = $report.runtime; total = $report.total; passed = $passed; failed = $failed; report = $reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
