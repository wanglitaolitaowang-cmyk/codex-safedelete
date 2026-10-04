# Real read-only Windows queries plus mocked case flags; no directory flags change.
[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $PSScriptRoot '.work' }
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\Storage.ps1')
$run = 'windows-filesystem-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$evidence = [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $run))
$null = [IO.Directory]::CreateDirectory($evidence)
$results = New-Object 'System.Collections.Generic.List[object]'
$script:caseEvidence = New-Object 'System.Collections.Generic.List[object]'
$script:mockPath = ''
$script:mockMode = ''
$script:mockHits = 0
$script:nativeCaseQuery = ${function:Get-SDWindowsDirectoryCaseSensitivity}

function Get-SDWindowsDirectoryCaseSensitivity {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:mockPath -and [string]::Equals($Path,$script:mockPath,[StringComparison]::OrdinalIgnoreCase)) {
        $script:mockHits++
        if ($script:mockMode -eq 'sensitive') {
            return [pscustomobject]@{ Confirmed=$true; CaseSensitive=$true; Method='mock-directory-flag'; ErrorCode=0; Reason='Mock sensitive directory; no real flag was changed.' }
        }
        return [pscustomobject]@{ Confirmed=$false; CaseSensitive=$false; Method='mock-unknown'; ErrorCode=50; Reason='Mock query failure with no reliable volume proof.' }
    }
    return & $script:nativeCaseQuery -Path $Path
}

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-FixtureSnapshot([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
        [pscustomobject]@{ path=$_.FullName; directory=$_.PSIsContainer; hash=$(if ($_.PSIsContainer) { $null } else { Get-Hash $_.FullName }) }
    })
}
function Assert-FixtureUnchanged([string]$Root,[object[]]$Before) {
    $after = @(Get-FixtureSnapshot $Root)
    Assert-True ($after.Count -eq $Before.Count) 'Denied operation changed the fixture directory/file count.'
    foreach ($entry in $Before) {
        $matches = @($after | Where-Object { $_.path -ceq $entry.path })
        Assert-True ($matches.Count -eq 1 -and $matches[0].directory -eq $entry.directory -and $matches[0].hash -ceq $entry.hash) ('Denied operation changed ' + $entry.path)
    }
    $script:caseEvidence.Add([pscustomobject]@{ preservedEntryCount=$Before.Count; historyFilesAndPayloadUnchanged=$true; realCaseFlagChanged=$false; mockedQueryCount=$script:mockHits })
}
function New-Fixture([string]$Name) {
    $path = Join-Path $evidence $Name
    $null = [IO.Directory]::CreateDirectory($path)
    return $path
}
function New-HistoryFixture([string]$Name) {
    $root = New-Fixture $Name
    $file = Join-Path $root 'previous.txt'
    [IO.File]::WriteAllText($file,'previous recoverable deletion')
    $record = Move-SafeDeleteItems $root @($file) 'rm previous.txt'
    [IO.File]::WriteAllText((Join-Path $root 'sentinel.txt'),'preserve existing source data')
    return [pscustomobject]@{ root=$root; record=$record }
}
function Expect-CaseDeny([scriptblock]$Body,[string]$Expected) {
    $message = ''
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like ('DENY: ' + $Expected + '*')) ('Expected a case-safety refusal; got: ' + $message)
    Assert-True ($script:mockHits -gt 0) 'The requested mock directory was never queried.'
}
function Test-Case([string]$Name,[scriptblock]$Body) {
    $script:caseEvidence.Clear()
    try {
        & $Body | Out-Null
        $results.Add([pscustomobject]@{ name=$Name; result='PASS'; error=$null; evidence=@($script:caseEvidence.ToArray()) })
    } catch {
        $results.Add([pscustomobject]@{ name=$Name; result='FAIL'; error=$_.Exception.Message; evidence=@($script:caseEvidence.ToArray()) })
    } finally {
        $script:mockPath = ''; $script:mockMode = ''; $script:mockHits = 0
    }
}

Test-Case 'ordinary Windows directory uses a real read-only native query' {
    $root = New-Fixture 'native-query'
    $file = Join-Path $root 'unchanged.txt'
    [IO.File]::WriteAllText($file,'read-only query fixture')
    $before = @(Get-FixtureSnapshot $root)
    $info = Get-SDWindowsDirectoryCaseSensitivity $root
    Assert-True ($info.Confirmed -and -not $info.CaseSensitive) ('Native query could not confirm the ordinary directory: ' + $info.Reason)
    Assert-True ($info.Method -in @('directory-flag','volume-capability')) 'Ordinary query did not use a native filesystem proof.'
    $null = Get-SDProjectRoot $root
    Assert-SDTarget $file $root
    Assert-FixtureUnchanged $root $before
    $script:caseEvidence.Add([pscustomobject]@{ queryMethod=$info.Method; confirmedInsensitive=$true; mockUsed=$false; realCaseSensitiveFixtureTested=$false })
}

Test-Case 'native case query supports an ordinary directory beyond MAX_PATH' {
    $root = New-Fixture 'native-long-path-query'
    $longPath = $root
    $component = 'long-directory-component-1234567890abcdef'
    while ($longPath.Length -le 300) { $longPath += '\' + $component }
    # This prefix is fixture setup only. Query receives the ordinary absolute
    # path, and this case does not claim the full delete/restore workflow works.
    $nativeFixture = '\\?\' + $longPath
    if ($longPath.StartsWith('\\')) { $nativeFixture = '\\?\UNC\' + $longPath.Substring(2) }
    $null = [IO.Directory]::CreateDirectory($nativeFixture)
    $sentinel = $nativeFixture + '\unchanged.txt'
    [IO.File]::WriteAllText($sentinel,'read-only long native query fixture')
    $before = Get-Hash $sentinel
    $info = Get-SDWindowsDirectoryCaseSensitivity $longPath
    Assert-True ($info.Confirmed -and -not $info.CaseSensitive) ('Native long-path query could not confirm the ordinary directory: ' + $info.Reason)
    Assert-True ($info.Method -in @('directory-flag','volume-capability')) 'Long-path query did not use a native filesystem proof.'
    Assert-True ((Get-Hash $sentinel) -ceq $before) 'Read-only native query changed the long-path sentinel.'
    $script:caseEvidence.Add([pscustomobject]@{ queryMethod=$info.Method; confirmedInsensitive=$true; pathLength=$longPath.Length; mockUsed=$false; sentinelHashUnchanged=$true; fullDeleteRestoreLongPathTested=$false; realCaseSensitiveFixtureTested=$false })
}

Test-Case 'mocked sensitive project ancestor refuses deletion before history changes' {
    $fixture = New-HistoryFixture 'sensitive-ancestor'
    $root = $fixture.root
    $target = Join-Path $root 'sentinel.txt'
    $before = @(Get-FixtureSnapshot $root)
    $script:mockPath = [IO.Directory]::GetParent($root).FullName
    $script:mockMode = 'sensitive'
    Expect-CaseDeny { Move-SafeDeleteItems $root @($target) 'rm sentinel.txt' } 'case-sensitive Windows directories are unsupported'
    Assert-FixtureUnchanged $root $before
}

Test-Case 'mocked sensitive child in a target tree refuses all payload moves' {
    $fixture = New-HistoryFixture 'sensitive-target-tree'
    $root = $fixture.root
    $target = Join-Path $root 'folder'
    $child = Join-Path $target 'child'
    $null = [IO.Directory]::CreateDirectory($child)
    [IO.File]::WriteAllText((Join-Path $child 'payload.txt'),'preserve the entire target tree')
    $before = @(Get-FixtureSnapshot $root)
    $script:mockPath = $child
    $script:mockMode = 'sensitive'
    Expect-CaseDeny { Move-SafeDeleteItems $root @($target) 'rm -r folder' } 'case-sensitive Windows directories are unsupported'
    Assert-FixtureUnchanged $root $before
}

Test-Case 'mocked sensitive restore destination refuses before journal and rename' {
    $root = New-Fixture 'sensitive-restore-parent'
    $parent = Join-Path $root 'destination'
    $null = [IO.Directory]::CreateDirectory($parent)
    $file = Join-Path $parent 'payload.txt'
    [IO.File]::WriteAllText($file,'recoverable payload')
    $record = Move-SafeDeleteItems $root @($file) 'rm destination/payload.txt'
    $before = @(Get-FixtureSnapshot $root)
    $script:mockPath = $parent
    $script:mockMode = 'sensitive'
    Expect-CaseDeny { Restore-SafeDeleteRecord $root $record.id } 'case-sensitive Windows directories are unsupported'
    Assert-FixtureUnchanged $root $before
    Assert-True (-not (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $record.items[0].trash_path)) 'Denied restore moved or lost its recoverable payload.'
}

Test-Case 'mocked unknown directory query refuses before history and payload changes' {
    $fixture = New-HistoryFixture 'unknown-directory'
    $root = $fixture.root
    $parent = Join-Path $root 'unconfirmed'
    $null = [IO.Directory]::CreateDirectory($parent)
    $file = Join-Path $parent 'payload.txt'
    [IO.File]::WriteAllText($file,'preserve this source payload')
    $before = @(Get-FixtureSnapshot $root)
    $script:mockPath = $parent
    $script:mockMode = 'unknown'
    Expect-CaseDeny { Move-SafeDeleteItems $root @($file) 'rm unconfirmed/payload.txt' } 'cannot reliably confirm Windows directory case sensitivity'
    Assert-FixtureUnchanged $root $before
}

$passed = @($results | Where-Object { $_.result -eq 'PASS' }).Count
$failed = $results.Count - $passed
$reportPath = Join-Path $evidence 'report.json'
$report = [pscustomobject]@{
    result=$(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); runtime=$PSVersionTable.PSVersion.ToString(); tested_at=[DateTime]::UtcNow.ToString('o')
    total=$results.Count; passed=$passed; failed=$failed; storage_sha256=(Get-Hash (Join-Path $project 'src\Storage.ps1'))
    realCaseSensitiveFixtureTested=$false; tests=@($results.ToArray()); fixtures=$evidence
}
[IO.File]::WriteAllText($reportPath,(ConvertTo-Json -InputObject $report -Depth 8),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ result=$report.result; runtime=$report.runtime; total=$results.Count; passed=$passed; failed=$failed; report=$reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
