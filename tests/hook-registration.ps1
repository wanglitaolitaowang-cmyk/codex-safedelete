[CmdletBinding()]
param([string]$SourceRoot, [string]$ArtifactRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path $PSScriptRoot '.work' }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$runId = 'hook-registration-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PSVersionTable.PSVersion.Major, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) $runId
[void][IO.Directory]::CreateDirectory($runRoot)
$project = Join-Path $runRoot 'project with spaces'
$foreignProject = Join-Path $runRoot 'other project'
$codexHome = Join-Path $runRoot 'isolated codex-home'
$hookPath = Join-Path $codexHome 'hooks.json'
$projectHookPath = Join-Path $project '.codex\hooks.json'
$expectedCommand = 'mock-only-safedelete-hook-command'
$hash = 'sha256:' + ('a' * 64)
$otherHash = 'sha256:' + ('b' * 64)
$key = $hookPath + ':pre_tool_use:0:0'
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:rpcWrites = New-Object 'System.Collections.Generic.List[object]'
$script:mockListings = @()
$script:listingIndex = 0
$script:starts = 0
$script:stops = 0

. (Join-Path $SourceRoot 'hooks\Trust.ps1')

# These replacements never start Codex or write a real configuration. Exercise
# the registration entry point and record exactly which RPC edits it requested.
function Start-SafeDeleteHookServer {
    param([string]$CodexHome, [string]$WorkingDirectory, [switch]$EnableHooks)
    $script:starts++
    return [pscustomobject]@{ number=$script:starts; enableHooks=[bool]$EnableHooks }
}

function Invoke-SafeDeleteHookRpc {
    param($Server, [string]$Method, [hashtable]$Params)
    if ($Method -ceq 'hooks/list') {
        if (@($Params.cwds).Count -ne 1 -or $Params.cwds[0] -cne $project) { throw 'Unexpected requested cwd in mock RPC.' }
        if ($script:listingIndex -ge $script:mockListings.Count) { throw 'Mock hooks/list queue exhausted.' }
        $listing = $script:mockListings[$script:listingIndex]
        $script:listingIndex++
        return $listing
    }
    if ($Method -ceq 'config/batchWrite') {
        $script:rpcWrites.Add($Params)
        return [pscustomobject]@{}
    }
    throw ('Unexpected RPC method: ' + $Method)
}

function Stop-SafeDeleteHookServer {
    param($Server)
    if ($null -ne $Server) { $script:stops++ }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestHook {
    param([hashtable]$Changes = @{})
    $hook = [pscustomobject][ordered]@{
        key=$key; eventName='preToolUse'; handlerType='command'; command=$expectedCommand
        async=$false; matcher='^(Bash|apply_patch)$'; timeoutSec=30; statusMessage='Codex SafeDelete'
        additionalContextLimit=$null; sourcePath=$hookPath; source='user'; pluginId=$null
        displayOrder=0; enabled=$true; isManaged=$false; currentHash=$hash; trustStatus='trusted'
    }
    foreach ($name in $Changes.Keys) { $hook | Add-Member -NotePropertyName $name -NotePropertyValue $Changes[$name] -Force }
    return $hook
}

function New-TestEntry {
    param([object[]]$Hooks, [string]$Cwd = $project, [object[]]$Errors = @(), [object[]]$Warnings = @())
    return [pscustomobject]@{ cwd=$Cwd; hooks=@($Hooks); warnings=@($Warnings); errors=@($Errors) }
}

function New-TestListing {
    param([object[]]$Hooks)
    return [pscustomobject]@{ data=@((New-TestEntry -Hooks $Hooks)) }
}

function Set-MockListing {
    param($First, $Reload)
    $script:mockListings = @($First)
    if ($null -ne $Reload) { $script:mockListings += $Reload }
    $script:listingIndex = 0
    $script:rpcWrites.Clear()
    $script:starts = 0
    $script:stops = 0
}

function Get-TestRegistration {
    param([switch]$Trust)
    return Get-SafeDeleteHookRegistration -CodexHome $codexHome -WorkingDirectory $project -HookPath $hookPath -ExpectedCommand $expectedCommand -Trust:$Trust
}

function Assert-Rejected {
    param([int]$ExpectedWrites = 0, [string]$MessagePattern = '', [switch]$NoTrust)
    $errorMessage = $null
    try { $null = Get-TestRegistration -Trust:(-not $NoTrust) } catch { $errorMessage = $_.Exception.Message }
    Assert-True ($null -ne $errorMessage) 'Registration unexpectedly succeeded.'
    Assert-True ($script:rpcWrites.Count -eq $ExpectedWrites) ('Unexpected configuration-write count: ' + $script:rpcWrites.Count)
    if ($MessagePattern) { Assert-True ($errorMessage -match $MessagePattern) ('Unexpected rejection: ' + $errorMessage) }
    Assert-True ($script:starts -eq $script:stops) 'A mocked server was not stopped after rejection.'
    return $errorMessage
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:results.Add([pscustomobject]@{ name=$Name; result='PASS'; error=$null })
    } catch {
        $script:results.Add([pscustomobject]@{ name=$Name; result='FAIL'; error=$_.Exception.Message })
    }
}

Test-Case 'One real registration succeeds without configuration writes' {
    Set-MockListing (New-TestListing @((New-TestHook)))
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $registration.CurrentHash -ceq $hash -and $registration.Enabled) 'Registration identity changed.'
    Assert-True ($script:rpcWrites.Count -eq 0 -and $script:starts -eq $script:stops) 'Read-only registration mutated state or leaked a server.'
}

Test-Case 'Zero matches report the same cwd SDK warning and complete diagnostic source' {
    $warning = 'hooks.json: unknown field fixture_metadata; expected description or hooks'
    Set-MockListing ([pscustomobject]@{ data=@((New-TestEntry -Hooks @() -Warnings @($warning))) })
    $message = Assert-Rejected -NoTrust
    Assert-True ($message.Contains($warning) -and $message.Contains('Full diagnostics: Codex hooks/list') -and
        $message.Contains('cwd=' + $project) -and $message.Contains('source=' + $hookPath)) 'SDK warning or its diagnostic source was lost.'
}

Test-Case 'Zero matches ignore other cwd warnings and non-string warning values' {
    $localWarning = 'Local configuration warning'
    $foreignWarning = 'Foreign project warning must stay excluded'
    $entry = New-TestEntry -Hooks @() -Warnings @($null,17,[pscustomobject]@{text='Invalid warning object'},' ', $localWarning)
    $foreign = New-TestEntry -Hooks @() -Cwd $foreignProject -Warnings @($foreignWarning)
    Set-MockListing ([pscustomobject]@{ data=@($entry,$foreign) })
    $message = Assert-Rejected -NoTrust
    Assert-True ($message.Contains($localWarning) -and -not $message.Contains($foreignWarning) -and
        -not $message.Contains('Invalid warning object') -and $message.Contains('1 of 1 shown')) 'An unrelated or invalid warning polluted the diagnostic.'
}

Test-Case 'Zero-match diagnostics bound warning previews and retain the full source' {
    $warnings = @(1..5 | ForEach-Object { 'Warning ' + $_ + ': ' + ('x' * 10000) })
    Set-MockListing ([pscustomobject]@{ data=@((New-TestEntry -Hooks @() -Warnings $warnings)) })
    $message = Assert-Rejected -NoTrust
    Assert-True ($message.Length -lt 4096 -and $message.Contains('3 of 5 shown') -and
        $message.Contains('[preview shortened]') -and -not $message.Contains('Warning 4:') -and
        $message.Contains('Full diagnostics: Codex hooks/list for cwd=' + $project)) 'Warning previews were unbounded or omitted their complete source.'
    Assert-True ($warnings[0].Length -gt 10000) 'The SDK warning source was modified while making a preview.'
}

Test-Case 'Warnings do not reject a unique valid registration' {
    $entry = New-TestEntry -Hooks @((New-TestHook)) -Warnings @('Another hook source has an unsupported field',23)
    Set-MockListing ([pscustomobject]@{ data=@($entry) })
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $script:rpcWrites.Count -eq 0 -and $script:starts -eq $script:stops) 'A warning changed a valid read-only registration.'
}

Test-Case 'Warnings preserve trust and reload verification for a unique registration' {
    $before = [pscustomobject]@{ data=@((New-TestEntry -Hooks @((New-TestHook @{trustStatus='untrusted'})) -Warnings @('Initial unrelated warning'))) }
    $after = [pscustomobject]@{ data=@((New-TestEntry -Hooks @((New-TestHook)) -Warnings @('Reload unrelated warning'))) }
    Set-MockListing $before $after
    $registration = Get-TestRegistration -Trust
    Assert-True ($registration.Key -ceq $key -and $script:rpcWrites.Count -eq 1 -and
        $script:listingIndex -eq 2 -and $script:starts -eq $script:stops) 'Warnings changed the required trust write or reload verification.'
}

Test-Case 'Identical returned rows collapse to one registration' {
    Set-MockListing (New-TestListing @((New-TestHook),(New-TestHook)))
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $script:rpcWrites.Count -eq 0) 'Identical rows were not recognized without writes.'
}

Test-Case 'Identical metadata with different property order is accepted' {
    $original = New-TestHook
    $reordered = [pscustomobject][ordered]@{}
    $properties = @($original.PSObject.Properties)
    for ($i=$properties.Count-1; $i -ge 0; $i--) { $reordered | Add-Member NoteProperty $properties[$i].Name $properties[$i].Value }
    Set-MockListing (New-TestListing @($original,$reordered))
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $script:rpcWrites.Count -eq 0) 'Property order changed semantic registration identity.'
}

Test-Case 'Trust identical rows writes once and verifies identical reload rows' {
    $before = New-TestListing @((New-TestHook @{trustStatus='untrusted'}),(New-TestHook @{trustStatus='untrusted'}))
    Set-MockListing $before (New-TestListing @((New-TestHook),(New-TestHook)))
    $registration = Get-TestRegistration -Trust
    Assert-True ($script:rpcWrites.Count -eq 1 -and $script:listingIndex -eq 2) 'Trust was not one write followed by one reload.'
    $edits = @($script:rpcWrites[0].edits)
    Assert-True ($edits.Count -eq 2 -and $edits[0].keyPath -ceq 'features.hooks' -and $edits[0].value -is [bool] -and $edits[0].value) 'Unexpected feature edit.'
    Assert-True ($edits[1].keyPath -ceq 'hooks.state' -and $edits[1].value.Count -eq 1 -and $edits[1].value[$key].trusted_hash -ceq $hash) 'Trust edited an unexpected identity or hash.'
    Assert-True ($registration.TrustStatus -ceq 'trusted' -and $script:starts -eq $script:stops) 'Reload did not confirm trusted registration or leaked a server.'
}

Test-Case 'Different keys remain real duplicate registrations and reject before writes' {
    Set-MockListing (New-TestListing @((New-TestHook),(New-TestHook @{key=($key + '-second')})))
    $message = Assert-Rejected -MessagePattern '2 distinct registration'
    Assert-True ($message.Contains($project) -and $message.Contains($hookPath) -and $message.Contains($key + '-second')) 'Duplicate diagnostics lack cwd/source/key.'
    Assert-True (-not $message.Contains($expectedCommand)) 'Duplicate diagnostics disclosed unrelated command text.'
}

Test-Case 'Keys differing only in case remain distinct registration identities' {
    Set-MockListing (New-TestListing @((New-TestHook),(New-TestHook @{key=$key.ToUpperInvariant()})))
    $null = Assert-Rejected -MessagePattern '2 distinct registration'
}

$conflicts = @(
    [pscustomobject]@{ name='currentHash'; value=$otherHash },
    [pscustomobject]@{ name='matcher'; value='^Read$' },
    [pscustomobject]@{ name='enabled'; value=$false },
    [pscustomobject]@{ name='trustStatus'; value='untrusted' },
    [pscustomobject]@{ name='sourcePath'; value=$projectHookPath },
    [pscustomobject]@{ name='eventName'; value='postToolUse' },
    [pscustomobject]@{ name='command'; value='different-command' },
    [pscustomobject]@{ name='source'; value='project' },
    [pscustomobject]@{ name='timeoutSec'; value=60 },
    [pscustomobject]@{ name='statusMessage'; value='CODEX SAFEDELETE' },
    [pscustomobject]@{ name='isManaged'; value=$true },
    [pscustomobject]@{ name='futureIdentityField'; value='different' }
)
foreach ($conflict in $conflicts) {
    Test-Case ('Same-key conflict in ' + $conflict.name + ' rejects before writes') {
        $changes = @{}; $changes[$conflict.name] = $conflict.value
        Set-MockListing (New-TestListing @((New-TestHook),(New-TestHook $changes)))
        $null = Assert-Rejected -MessagePattern 'Conflicting SafeDelete Hook rows'
    }
}

Test-Case 'One disabled registration rejects before writes' {
    Set-MockListing (New-TestListing @((New-TestHook @{enabled=$false})))
    $null = Assert-Rejected -MessagePattern 'disabled'
}

$invalidValues = @(
    [pscustomobject]@{ name='key'; value='' },
    [pscustomobject]@{ name='key'; value=123 },
    [pscustomobject]@{ name='currentHash'; value='sha256:abc' },
    [pscustomobject]@{ name='currentHash'; value=('a' * 64) },
    [pscustomobject]@{ name='currentHash'; value=123 },
    [pscustomobject]@{ name='enabled'; value='true' },
    [pscustomobject]@{ name='enabled'; value=1 },
    [pscustomobject]@{ name='matcher'; value=123 },
    [pscustomobject]@{ name='trustStatus'; value=$true },
    [pscustomobject]@{ name='async'; value='false' },
    [pscustomobject]@{ name='isManaged'; value=0 },
    [pscustomobject]@{ name='timeoutSec'; value='30' }
)
foreach ($invalid in $invalidValues) {
    Test-Case ('Malformed ' + $invalid.name + ' metadata (' + [string]$invalid.value + ') rejects before writes') {
        $changes = @{}; $changes[$invalid.name] = $invalid.value
        Set-MockListing (New-TestListing @((New-TestHook $changes)))
        $null = Assert-Rejected -MessagePattern 'Invalid SafeDelete Hook metadata'
    }
}

Test-Case 'Missing boolean enabled field rejects before writes' {
    $hook = New-TestHook; $hook.PSObject.Properties.Remove('enabled')
    Set-MockListing (New-TestListing @($hook))
    $null = Assert-Rejected -MessagePattern 'enabled must be boolean'
}

Test-Case 'Project-source hook does not duplicate the expected global-source hook' {
    $other = New-TestHook @{key=($projectHookPath + ':pre_tool_use:0:0');sourcePath=$projectHookPath;source='project'}
    Set-MockListing (New-TestListing @((New-TestHook),$other))
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $registration.SourcePath -ceq $hookPath -and $script:rpcWrites.Count -eq 0) 'Project hook contaminated global registration.'
}

Test-Case 'Expected project-source hook is selected independently of a global-source hook' {
    $other = New-TestHook @{key=($projectHookPath + ':pre_tool_use:0:0');sourcePath=$projectHookPath;source='project'}
    Set-MockListing (New-TestListing @((New-TestHook),$other))
    $registration = Get-SafeDeleteHookRegistration -CodexHome $codexHome -WorkingDirectory $project -HookPath $projectHookPath -ExpectedCommand $expectedCommand
    Assert-True ($registration.Key -ceq $other.key -and $registration.SourcePath -ceq $projectHookPath -and $script:rpcWrites.Count -eq 0) 'Global hook contaminated project registration.'
}

Test-Case 'Foreign cwd rows and errors cannot contaminate the requested cwd' {
    $foreignHook = New-TestHook @{currentHash=$otherHash}
    $listing = [pscustomobject]@{data=@((New-TestEntry @((New-TestHook))),(New-TestEntry @($foreignHook) -Cwd $foreignProject -Errors @([pscustomobject]@{message='foreign error'})))}
    Set-MockListing $listing
    $registration = Get-TestRegistration
    Assert-True ($registration.CurrentHash -ceq $hash -and $script:rpcWrites.Count -eq 0) 'Foreign cwd rows or errors contaminated registration.'
}

Test-Case 'Only foreign cwd rows cannot supply a registration' {
    Set-MockListing ([pscustomobject]@{data=@((New-TestEntry @((New-TestHook)) -Cwd $foreignProject))})
    $null = Assert-Rejected -MessagePattern 'no Hook listing for cwd'
}

Test-Case 'Duplicate entries for the same cwd still collapse identical rows' {
    Set-MockListing ([pscustomobject]@{data=@((New-TestEntry @((New-TestHook))),(New-TestEntry @((New-TestHook))))})
    $registration = Get-TestRegistration
    Assert-True ($registration.Key -ceq $key -and $script:rpcWrites.Count -eq 0) 'Repeated cwd entries were mistaken for real duplicates.'
}

Test-Case 'Requested cwd configuration errors reject before writes' {
    Set-MockListing ([pscustomobject]@{data=@((New-TestEntry @((New-TestHook)) -Errors @([pscustomobject]@{message='local error'})))})
    $null = Assert-Rejected -MessagePattern 'configuration has 1 error'
}

Test-Case 'Reload changed hash rejects after the single authorized trust write' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) (New-TestListing @((New-TestHook @{currentHash=$otherHash})))
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern 'did not confirm the same'
}

Test-Case 'Reload changed matcher rejects after the single trust write' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) (New-TestListing @((New-TestHook @{matcher='^Read$'})))
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern 'did not confirm the same'
}

Test-Case 'Reload real duplicate registration rejects without a second write' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) (New-TestListing @((New-TestHook),(New-TestHook @{key=($key + '-second')})))
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern '2 distinct registration'
}

Test-Case 'Reload conflicting duplicate hash rejects without a second write' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) (New-TestListing @((New-TestHook),(New-TestHook @{currentHash=$otherHash})))
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern 'Conflicting SafeDelete Hook rows'
}

Test-Case 'Reload foreign cwd cannot confirm trust' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) ([pscustomobject]@{data=@((New-TestEntry @((New-TestHook)) -Cwd $foreignProject))})
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern 'no Hook listing for cwd'
}

Test-Case 'Reload still untrusted rejects without a second write' {
    Set-MockListing (New-TestListing @((New-TestHook @{trustStatus='untrusted'}))) (New-TestListing @((New-TestHook @{trustStatus='untrusted'})))
    $null = Assert-Rejected -ExpectedWrites 1 -MessagePattern 'did not confirm the same'
}

$sourceHashes = @()
foreach ($relative in @('hooks\Trust.ps1','tests\hook-registration.ps1')) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $SourceRoot $relative)))).Replace('-', '') }
    finally { $sha.Dispose() }
    $sourceHashes += [pscustomobject]@{ path=$relative; sha256=$digest }
}
$passed = @($script:results | Where-Object { $_.result -ceq 'PASS' }).Count
$failed = $script:results.Count - $passed
$report = [pscustomobject]@{runId=$runId;powershell=$PSVersionTable.PSVersion.ToString();total=$script:results.Count;passed=$passed;failed=$failed;sourceHashes=$sourceHashes;results=$script:results.ToArray()}
$reportPath = Join-Path $runRoot 'results.json'
[IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ('TOTAL: {0}; PASS: {1}; FAIL: {2}' -f $report.total,$passed,$failed)
Write-Host ('Evidence: ' + $reportPath)
if ($failed -gt 0) { exit 1 }
exit 0
