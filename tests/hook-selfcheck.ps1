# Exercise the real self-check process with controlled fixture hook runtimes.
[CmdletBinding()]
param([string]$SourceRoot,[string]$ArtifactRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$workRoot = [IO.Path]::GetFullPath((Join-Path $SourceRoot 'tests\.work'))
if (-not $ArtifactRoot) { $ArtifactRoot = $workRoot }
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
if (-not [string]::Equals($ArtifactRoot,$workRoot,[StringComparison]::OrdinalIgnoreCase) -and
    -not $ArtifactRoot.StartsWith($workRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Hook self-check fixtures must stay inside tests/.work.' }
$module = Join-Path $SourceRoot 'src\InstallState.ps1'
. $module
$run = 'hook-selfcheck-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$runRoot = Join-Path $ArtifactRoot $run
$null = [IO.Directory]::CreateDirectory($runRoot)
$results = New-Object 'System.Collections.Generic.List[object]'
$script:caseEvidence = New-Object 'System.Collections.Generic.List[object]'
$encoding = New-Object Text.UTF8Encoding($false)
$stub = Join-Path $runRoot 'fixture-hook.ps1'
$stubText = @'
[CmdletBinding()]
param([string]$Mode,[string]$EvidencePath)
$ErrorActionPreference = 'Stop'
$inputStream = [Console]::OpenStandardInput()
$reader = New-Object IO.StreamReader($inputStream,(New-Object Text.UTF8Encoding($false)))
try { $request = $reader.ReadToEnd() | ConvertFrom-Json }
finally { $reader.Dispose() }
if ($request.hook_event_name -cne 'PreToolUse' -or $request.tool_name -cne 'Bash' -or
    $request.tool_input.command -cne 'Remove-Item -Recurse -Force .') { throw 'Fixture hook received an unexpected self-check request.' }
$normalReason = "Codex SafeDelete`nDENY: The project root, its parents, and paths outside the project are blocked.`nCommand: Remove-Item -Recurse -Force ."
$faultReason = 'Codex SafeDelete: Hook verification failed or exceeded its safety budget. Original command denied. Run safedelete status.'
$response = [pscustomobject]@{ hookSpecificOutput=[pscustomobject]@{ hookEventName='PreToolUse'; permissionDecision='deny'; permissionDecisionReason=$normalReason } }
$stderrText = ''
switch ($Mode) {
    'fault' { $response.hookSpecificOutput.permissionDecisionReason=$faultReason }
    'fault-stderr' { $response.hookSpecificOutput.permissionDecisionReason=$faultReason; $stderrText='Codex SafeDelete: Hook verification failed (input); original command denied.' }
    'normal-stderr' { $stderrText='Codex SafeDelete: Hook verification failed (worker-runtime); original command denied.' }
    'off' { $response=[pscustomobject]@{} }
    'off-stderr' { $response=[pscustomobject]@{}; $stderrText='Codex SafeDelete: Hook verification failed (worker-runtime); original command denied.' }
    'array' { }
    'string' { }
    'capitalized-root' { $response=[pscustomobject]@{ HookSpecificOutput=$response.hookSpecificOutput } }
    'capitalized-event' { $response.hookSpecificOutput=[pscustomobject]@{ HookEventName='PreToolUse'; permissionDecision='deny'; permissionDecisionReason=$normalReason } }
    'capitalized-decision' { $response.hookSpecificOutput=[pscustomobject]@{ hookEventName='PreToolUse'; PermissionDecision='deny'; permissionDecisionReason=$normalReason } }
    'capitalized-reason' { $response.hookSpecificOutput=[pscustomobject]@{ hookEventName='PreToolUse'; permissionDecision='deny'; PermissionDecisionReason=$normalReason } }
    'normal' { }
    default { throw 'Unknown fixture response mode.' }
}
$stdoutText = ConvertTo-Json -InputObject $response -Depth 5 -Compress
if ($Mode -eq 'array') { $stdoutText='[' + $stdoutText + ']' }
if ($Mode -eq 'string') { $stdoutText='"deny"' }
[IO.File]::WriteAllText($EvidencePath,(ConvertTo-Json -InputObject ([pscustomobject]@{ mode=$Mode; request=$request; stdout=$stdoutText; stderr=$stderrText }) -Depth 6),(New-Object Text.UTF8Encoding($false)))
if ($stderrText) { [Console]::Error.WriteLine($stderrText) }
[Console]::Out.WriteLine($stdoutText)
exit 0
'@
[IO.File]::WriteAllText($stub,$stubText,$encoding)
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-FixtureCheck([string]$Mode,[string]$ExpectedDecision,[bool]$ShouldPass) {
    $evidencePath = Join-Path $runRoot ($Mode + '-' + $ExpectedDecision + '.json')
    $command = "& '" + $stub.Replace("'","''") + "' -Mode '" + $Mode + "' -EvidencePath '" + $evidencePath.Replace("'","''") + "'"
    $message = ''
    try { Test-SafeDeleteHookCommand -HookCommand $command -ProjectRoot $runRoot -ExpectedDecision $ExpectedDecision }
    catch { $message=$_.Exception.Message }
    $passed = [string]::IsNullOrWhiteSpace($message)
    $script:caseEvidence.Add([pscustomobject]@{ mode=$Mode; expectedDecision=$ExpectedDecision; verificationAccepted=$passed; expectedAccepted=$ShouldPass; error=$message; processEvidence=$evidencePath })
    Assert-True ([IO.File]::Exists($evidencePath)) 'The actual fixture hook process did not record its request and response.'
    Assert-True ($passed -eq $ShouldPass) ('Self-check accepted an unhealthy response or rejected a healthy response: ' + $Mode + '; ' + $message)
}
function Test-Case([string]$Name,[scriptblock]$Body) {
    $script:caseEvidence.Clear()
    try {
        & $Body | Out-Null
        $results.Add([pscustomobject]@{ name=$Name; result='PASS'; error=$null; evidence=@($script:caseEvidence.ToArray()) })
    } catch {
        $results.Add([pscustomobject]@{ name=$Name; result='FAIL'; error=$_.Exception.Message; evidence=@($script:caseEvidence.ToArray()) })
    }
}
$moduleHash = Get-SafeDeleteFileHash $module
$userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$processPathBefore = $env:Path
Test-Case 'fault denials, stderr and invalid root shapes cannot confirm healthy protection' {
    foreach ($mode in @('fault','fault-stderr','normal-stderr','array','string','capitalized-root','capitalized-event','capitalized-decision','capitalized-reason')) { Invoke-FixtureCheck $mode 'deny' $false }
    Invoke-FixtureCheck 'off-stderr' 'bypass' $false
}
Test-Case 'normal project-root policy denial confirms healthy ON' {
    Invoke-FixtureCheck 'normal' 'deny' $true
}
Test-Case 'an empty object with no stderr confirms OFF' {
    Invoke-FixtureCheck 'off' 'bypass' $true
}
$failed = @($results | Where-Object { $_.result -eq 'FAIL' }).Count
$sourceUnchanged = (Get-SafeDeleteFileHash $module) -ceq $moduleHash
$userPathUnchanged = [string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)
$processPathUnchanged = [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)
if (-not $sourceUnchanged -or -not $userPathUnchanged -or -not $processPathUnchanged) { $failed++ }
$reportPath = Join-Path $runRoot 'report.json'
$report = [pscustomobject]@{
    result=$(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); runtime=$PSVersionTable.PSVersion.ToString(); tested_at=[DateTime]::UtcNow.ToString('o')
    total=$results.Count; passed=@($results | Where-Object { $_.result -eq 'PASS' }).Count; failed=$failed
    sourceUnchanged=$sourceUnchanged; userPathUnchanged=$userPathUnchanged; processPathUnchanged=$processPathUnchanged
    install_state_sha256=$moduleHash; tests=@($results.ToArray()); fixtures=$runRoot
}
[IO.File]::WriteAllText($reportPath,(ConvertTo-Json -InputObject $report -Depth 8),$encoding)
[pscustomobject]@{ result=$report.result; runtime=$report.runtime; total=$report.total; passed=$report.passed; failed=$failed; report=$reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
