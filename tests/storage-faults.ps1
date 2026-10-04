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

Test-Case 'pending move failure is recoverable' {
    $root = New-Fixture 'pending'
    $a = Join-Path $root 'a.txt'; $b = Join-Path $root 'b.txt'
    [IO.File]::WriteAllText($a, 'first'); [IO.File]::WriteAllText($b, 'second')
    # No FILE_SHARE_DELETE: the second rename genuinely fails on Windows.
    $handle = [IO.File]::Open($b, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
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
    $handle = [IO.File]::Open($record.items[1].trash_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
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

Test-Case 'pending record with no payload does not claim success' {
    $root = New-Fixture 'zero-payload'
    $file = Join-Path $root 'payload.txt'
    [IO.File]::WriteAllText($file, 'payload')
    $record = Move-SafeDeleteItems $root @($file) 'rm payload.txt'
    $history = @(Get-SafeDeleteHistory $root)
    $history[0].status = 'pending'
    Write-SDHistory (Join-Path $root '.codex-safedelete') $history
    [IO.File]::Move($record.items[0].trash_path, $file)
    $failed = $false
    try { $null = Restore-SafeDeleteRecord $root }
    catch { if ($_.Exception.Message -like 'No recoverable payload exists*') { $failed = $true } else { throw } }
    Assert-True $failed 'An empty recovery incorrectly reported success.'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'payload') 'The original file changed.'
    Assert-True (@(Get-SafeDeleteHistory $root)[0].status -eq 'pending') 'An empty recovery marked the record restored.'
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
