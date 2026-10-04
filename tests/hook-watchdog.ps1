[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ArtifactRoot,
    [string]$ShellPath = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path $PSScriptRoot '.work' }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$runId = 'hook-watchdog-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PSVersionTable.PSVersion.Major, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) $runId
$fixtureRoot = Join-Path $runRoot ('parent with spaces ' + [char]0x6D4B + [char]0x8BD5 + ' $literal''s')
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8 = New-Object Text.UTF8Encoding($false)
$scriptEncoding = New-Object Text.UTF8Encoding($true)
$sourcePath = Join-Path $SourceRoot 'hooks\pre-tool-use.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$beginMarker = '# BEGIN SAFEDELETE WORKER'
$endMarker = '# END SAFEDELETE WORKER'
$begin = $source.IndexOf($beginMarker, [StringComparison]::Ordinal)
$end = $source.IndexOf($endMarker, [StringComparison]::Ordinal)
if ($begin -lt 0 -or $end -lt $begin -or -not $source.Contains('$watchdogMilliseconds = 20000')) { throw 'Watchdog fixture markers or production budget changed; update the test fixture deliberately.' }
$end += $endMarker.Length
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:processEvidence = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureNumber = 0
$requestBytes = $utf8.GetBytes('{"hook_event_name":"PreToolUse","cwd":"C:\\disposable","tool_name":"Bash","tool_input":{"command":"Write-Output fixture"}}')
$validDeny = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"fixture denial"}}'
$validAllow = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"fixture rewrite","updatedInput":{"command":"Write-Output fixture"}},"systemMessage":"fixture rewrite"}'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-ParentFixture {
    param([string]$WorkerCode, [switch]$SkipInputRead)
    $script:fixtureNumber++
    $path = Join-Path $fixtureRoot ('pre-tool-use-' + $script:fixtureNumber + '.ps1')
    # Only the copy's worker body and deadline change. The production parent,
    # process boundary, pipe handling and output validation run unchanged.
    $readInput = if ($SkipInputRead) { '' } else { '$null = [Console]::In.ReadToEnd(); ' }
    $encoding = '[Console]::InputEncoding = New-Object Text.UTF8Encoding($false); [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); '
    $stub = $beginMarker + "`r`n" + 'if ($Worker) { ' + $encoding + $readInput + $WorkerCode + " }`r`n" + $endMarker
    $copy = $source.Substring(0, $begin) + $stub + $source.Substring($end)
    $copy = $copy.Replace('$watchdogMilliseconds = 20000', '$watchdogMilliseconds = 2500')
    # Windows PowerShell 5.1 needs a BOM to read Unicode fixture source paths.
    [IO.File]::WriteAllText($path, $copy, $scriptEncoding)
    return $path
}

function New-OutputFixture {
    param([string]$Output, [int]$ExitCode = 0)
    $code = '[Console]::Out.WriteLine(''' + $Output.Replace("'", "''") + '''); exit ' + $ExitCode
    return New-ParentFixture $code
}

function New-ProductionFixture {
    param([bool]$Enabled)
    $script:fixtureNumber++
    $directory = Join-Path $fixtureRoot ('production-' + $script:fixtureNumber)
    $hooksDirectory = Join-Path $directory 'hooks'
    $srcDirectory = Join-Path $directory 'src'
    $projectDirectory = Join-Path $directory 'project'
    foreach ($path in @($hooksDirectory,$srcDirectory,$projectDirectory,(Join-Path $projectDirectory '.codex-safedelete'))) { [void][IO.Directory]::CreateDirectory($path) }
    foreach ($module in @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'src') -Filter '*.ps1' -File)) {
        [IO.File]::WriteAllBytes((Join-Path $srcDirectory $module.Name), [IO.File]::ReadAllBytes($module.FullName))
    }
    $path = Join-Path $hooksDirectory 'pre-tool-use.ps1'
    [IO.File]::WriteAllText($path, $source, $scriptEncoding)
    [IO.File]::WriteAllText((Join-Path $directory 'protection-state.json'), (@{enabled=$Enabled}|ConvertTo-Json -Compress), $utf8)
    return [pscustomobject]@{ hook=$path; project=$projectDirectory }
}

function New-RequestBytes {
    param([string]$Project, [string]$Command, [int]$Padding = 0)
    $request = @{hook_event_name='PreToolUse';cwd=$Project;tool_name='Bash';tool_input=@{command=$Command}}
    if ($Padding -gt 0) { $request['padding'] = 'p' * $Padding }
    return $utf8.GetBytes(($request | ConvertTo-Json -Depth 5 -Compress))
}

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-ParentFixture {
    param([string]$Path, [byte[]]$InputBytes = $requestBytes, [switch]$KeepInputOpen)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Path)
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $fixtureRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Fixture parent did not start.' }
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        try {
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        } catch [IO.IOException] {
            # An oversized input can close the pipe while this final write is
            # finishing. The parent's decision and exit status still decide.
        }
        if (-not $KeepInputOpen) { $process.StandardInput.Close() }
        if (-not $process.WaitForExit(8000)) { throw 'Fixture parent exceeded 8 seconds.' }
        Assert-True ($stdout.Wait(1000) -and $stderr.Wait(1000)) 'Fixture output pipes did not close.'
        $watch.Stop()
        $result = [pscustomobject]@{ fixture=$Path; exitCode=$process.ExitCode; elapsedMilliseconds=$watch.ElapsedMilliseconds; stdout=$stdout.Result; stderr=$stderr.Result }
        $script:processEvidence.Add($result)
        return $result
    } finally {
        if ($started) { try { if (-not $process.HasExited) { $process.Kill() } } catch { } }
        $process.Dispose()
    }
}

function Assert-ParentDeny {
    param($Result)
    Assert-True ($Result.exitCode -eq 0) ('Fail-closed parent exited nonzero: ' + $Result.exitCode)
    $decision = ConvertFrom-Json -InputObject $Result.stdout -ErrorAction Stop
    Assert-True ($decision.hookSpecificOutput.hookEventName -ceq 'PreToolUse' -and $decision.hookSpecificOutput.permissionDecision -ceq 'deny') 'Parent did not return a structured PreToolUse denial.'
    Assert-True ($Result.elapsedMilliseconds -lt 6000) ('Parent exceeded the fixture deadline allowance: ' + $Result.elapsedMilliseconds)
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

Test-Case 'Hanging worker is denied within the budget and terminated' {
    $pidPath = Join-Path $fixtureRoot 'hanging-worker.pid'
    $code = '[IO.File]::WriteAllText(''' + $pidPath.Replace("'", "''") + ''', [Diagnostics.Process]::GetCurrentProcess().Id.ToString()); Start-Sleep -Milliseconds 10000; [Console]::Out.WriteLine(''{}''); exit 0'
    $result = Invoke-ParentFixture (New-ParentFixture $code)
    Assert-ParentDeny $result
    Assert-True ([IO.File]::Exists($pidPath)) 'Hanging worker never reached its fixture body.'
    $workerId = [int][IO.File]::ReadAllText($pidPath)
    $running = $true
    $killDeadline = [DateTime]::UtcNow.AddMilliseconds(1000)
    do {
        $workerProcess = $null
        try { $workerProcess = [Diagnostics.Process]::GetProcessById($workerId); $running = -not $workerProcess.HasExited }
        catch [ArgumentException] { $running = $false }
        finally { if ($null -ne $workerProcess) { $workerProcess.Dispose() } }
        if ($running) { Start-Sleep -Milliseconds 25 }
    } while ($running -and [DateTime]::UtcNow -lt $killDeadline)
    Assert-True (-not $running) 'Timed-out worker remained running after parent denial.'
}

Test-Case 'Nonzero worker exit with no output becomes denial and exit zero' {
    Assert-ParentDeny (Invoke-ParentFixture (New-ParentFixture 'exit 17'))
}

Test-Case 'Nonzero worker exit cannot smuggle a normal allow object' {
    Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture '{}' -ExitCode 17))
}

Test-Case 'Empty worker output becomes denial and exit zero' {
    Assert-ParentDeny (Invoke-ParentFixture (New-ParentFixture 'exit 0'))
}

Test-Case 'Repeated fast worker denial survives Windows input-pipe close races' {
    $code = '[Console]::Out.WriteLine(''' + $validDeny.Replace("'", "''") + '''); exit 0'
    $path = New-ParentFixture $code -SkipInputRead
    $largeRequest = New-RequestBytes $fixtureRoot 'Write-Output fixture' -Padding 262144
    for ($i=0; $i -lt 5; $i++) {
        $result = Invoke-ParentFixture $path -InputBytes $largeRequest
        $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
        Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecisionReason -ceq 'fixture denial') 'A valid, completed worker denial was lost to an input-pipe race.'
    }
}

Test-Case 'Undelivered input cannot accept an unchecked worker empty allow object' {
    $path = New-ParentFixture '[Console]::Out.WriteLine(''{}''); exit 0' -SkipInputRead
    $largeRequest = New-RequestBytes $fixtureRoot 'Write-Output fixture' -Padding 262144
    Assert-ParentDeny (Invoke-ParentFixture $path -InputBytes $largeRequest)
}

Test-Case 'Undelivered input cannot accept an unchecked worker command replacement' {
    $code = '[Console]::Out.WriteLine(''' + $validAllow.Replace("'", "''") + '''); exit 0'
    $path = New-ParentFixture $code -SkipInputRead
    $largeRequest = New-RequestBytes $fixtureRoot 'Write-Output fixture' -Padding 262144
    Assert-ParentDeny (Invoke-ParentFixture $path -InputBytes $largeRequest)
}

Test-Case 'Production OFF worker drains a real large request and returns normal allow' {
    $fixture = New-ProductionFixture $false
    $bytes = New-RequestBytes $fixture.project 'Remove-Item -Recurse -Force .' -Padding 262144
    $result = Invoke-ParentFixture $fixture.hook -InputBytes $bytes
    Assert-True ($result.exitCode -eq 0 -and $result.stdout.Trim() -ceq '{}' -and [string]::IsNullOrEmpty($result.stderr)) 'Real paused protection did not consume its request and return normal allow.'
}

Test-Case 'Production ON worker checks a real ordinary command and returns normal allow' {
    $fixture = New-ProductionFixture $true
    $bytes = New-RequestBytes $fixture.project 'Write-Output fixture'
    $result = Invoke-ParentFixture $fixture.hook -InputBytes $bytes
    Assert-True ($result.exitCode -eq 0 -and $result.stdout.Trim() -ceq '{}' -and [string]::IsNullOrEmpty($result.stderr)) 'Real active protection blanket-denied an ordinary command.'
}

Test-Case 'Production ON worker produces a real deletion replacement without moving files' {
    $fixture = New-ProductionFixture $true
    $target = Join-Path $fixture.project 'payload.txt'
    [IO.File]::WriteAllText($target, 'unchanged fixture payload', $utf8)
    $bytes = New-RequestBytes $fixture.project 'Remove-Item -LiteralPath payload.txt'
    $result = Invoke-ParentFixture $fixture.hook -InputBytes $bytes
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'allow' -and -not [string]::IsNullOrWhiteSpace($parsed.hookSpecificOutput.updatedInput.command)) 'Real active protection did not produce its safe replacement.'
    Assert-True ([IO.File]::Exists($target) -and [IO.File]::ReadAllText($target) -ceq 'unchanged fixture payload') 'The Hook worker moved or modified the payload itself.'
    Assert-True ([string]::IsNullOrEmpty($result.stderr)) 'Real replacement worker returned runtime errors.'
}

$invalidOutputs = @(
    [pscustomobject]@{ name='Malformed JSON'; value='{"broken":' },
    [pscustomobject]@{ name='Multiple adjacent JSON objects'; value='{}{}' },
    [pscustomobject]@{ name='Multiple newline-separated JSON objects'; value="{}`r`n{}" },
    [pscustomobject]@{ name='Array output'; value='[]' },
    [pscustomobject]@{ name='Wrong hook event'; value='{"hookSpecificOutput":{"hookEventName":"PostToolUse","permissionDecision":"deny","permissionDecisionReason":"fixture"}}' },
    [pscustomobject]@{ name='Bare allow decision'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}' },
    [pscustomobject]@{ name='Allow missing replacement command'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{}}}' },
    [pscustomobject]@{ name='Allow non-string replacement command'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":123}}}' },
    [pscustomobject]@{ name='Allow wrong-case replacement command'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"Command":"Remove-Item fixture"}}}' },
    [pscustomobject]@{ name='Allow replacement keys differing only in case'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"fixture","Command":"other"}}}' },
    [pscustomobject]@{ name='Allow replacement with extra input fields'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"fixture","shell":"unexpected"}}}' },
    [pscustomobject]@{ name='Deny non-string reason'; value='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":true}}' },
    [pscustomobject]@{ name='Unrecognized top-level fields'; value='{"continue":true}' }
)
foreach ($invalid in $invalidOutputs) {
    Test-Case ($invalid.name + ' becomes denial and exit zero') {
        Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture $invalid.value))
    }
}

Test-Case 'Valid structured deny preserves its decision and reason' {
    $result = Invoke-ParentFixture (New-OutputFixture $validDeny)
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and $parsed.hookSpecificOutput.permissionDecisionReason -ceq 'fixture denial') 'Valid deny semantics changed or failed.'
}

Test-Case 'Valid allow preserves its replacement command and system message' {
    $result = Invoke-ParentFixture (New-OutputFixture $validAllow)
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'allow' -and $parsed.hookSpecificOutput.updatedInput.command -ceq 'Write-Output fixture' -and $parsed.systemMessage -ceq 'fixture rewrite') 'Valid replacement semantics changed or failed.'
}

Test-Case 'Empty JSON object preserves normal allow and paused protection behavior' {
    $result = Invoke-ParentFixture (New-OutputFixture '{}')
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -ceq ('{}' + [Environment]::NewLine)) 'Normal allow object was changed or blocked.'
}

Test-Case 'Large worker stderr cannot deadlock stdout collection' {
    $code = '[Console]::Error.Write((''e'' * 131072)); [Console]::Out.WriteLine(''' + $validDeny.Replace("'", "''") + '''); exit 0'
    $result = Invoke-ParentFixture (New-ParentFixture $code)
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and $parsed.hookSpecificOutput.permissionDecisionReason -ceq 'fixture denial') 'Worker stderr blocked or corrupted its valid decision.'
    Assert-True ([string]::IsNullOrEmpty($result.stderr)) 'Parent copied large worker stderr into its output.'
}

Test-Case 'Unicode and escaped quotes in valid output remain exact' {
    $reason = ([char]0x6D4B).ToString() + [char]0x8BD5 + ' "quote" {literal} \\path'
    $json = @{hookSpecificOutput=@{hookEventName='PreToolUse';permissionDecision='deny';permissionDecisionReason=$reason}} | ConvertTo-Json -Depth 4 -Compress
    $result = Invoke-ParentFixture (New-OutputFixture $json)
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecisionReason -ceq $reason) 'Unicode/quoted string content changed between worker and parent.'
}

Test-Case 'Complex replacement command remains identical after normalization' {
    $command = 'Write-Output ''$literal "quotes" {braces} \\path''' + [Environment]::NewLine + ([char]0x6D4B).ToString() + [char]0x8BD5
    $json = @{hookSpecificOutput=@{hookEventName='PreToolUse';permissionDecision='allow';updatedInput=@{command=$command}}} | ConvertTo-Json -Depth 4 -Compress
    $result = Invoke-ParentFixture (New-OutputFixture $json)
    $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
    Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'allow' -and $parsed.hookSpecificOutput.updatedInput.command -ceq $command) 'Normalization changed a replacement command character.'
}

$looseOutputs = @(
    [pscustomobject]@{name='Trailing comma';value=($validDeny.Substring(0,$validDeny.Length-1)+',}')},
    [pscustomobject]@{name='JSON comment';value=$validDeny.Insert(1,'/*fixture*/')},
    [pscustomobject]@{name='Single-quoted JSON';value=$validDeny.Replace([char]34,[char]39)},
    [pscustomobject]@{name='Bare property name';value=$validDeny.Replace('"hookSpecificOutput"','hookSpecificOutput')}
)
foreach ($loose in $looseOutputs) {
    Test-Case ($loose.name + ' is normalized or safely denied according to runtime parsing') {
        $supported = $true
        try { $null = ConvertFrom-Json -InputObject $loose.value -ErrorAction Stop } catch { $supported = $false }
        $result = Invoke-ParentFixture (New-OutputFixture $loose.value)
        $parsed = ConvertFrom-Json -InputObject $result.stdout -ErrorAction Stop
        if ($supported) {
            Assert-True ($result.exitCode -eq 0 -and $parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and $parsed.hookSpecificOutput.permissionDecisionReason -ceq 'fixture denial') 'Supported loose syntax changed denial semantics.'
            Assert-True ($result.stdout -ceq ($validDeny + [Environment]::NewLine)) 'Loose syntax remained in the output sent to Codex.'
        } else { Assert-ParentDeny $result }
    }
}

Test-Case 'Same-name duplicate decision keys normalize to one strict final value' {
    $json = $validDeny.Replace('"permissionDecision":"deny"','"permissionDecision":"allow","permissionDecision":"deny"')
    $result = Invoke-ParentFixture (New-OutputFixture $json)
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -ceq ($validDeny + [Environment]::NewLine)) 'Duplicate JSON fields survived normalization or changed the final denial.'
}

Test-Case 'Descendant holding an inherited output pipe cannot extend the parent budget' {
    $pidPath = Join-Path $fixtureRoot 'pipe-holder.pid'
    $code = '$childStart = New-Object Diagnostics.ProcessStartInfo; $childStart.FileName = ''' + $ShellPath.Replace("'", "''") + '''; $childStart.Arguments = ''-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 10000"''; $childStart.UseShellExecute = $false; $childStart.CreateNoWindow = $true; $child = [Diagnostics.Process]::Start($childStart); [IO.File]::WriteAllText(''' + $pidPath.Replace("'", "''") + ''', $child.Id.ToString()); $child.Dispose(); [Console]::Out.WriteLine(''{}''); exit 0'
    try {
        $result = Invoke-ParentFixture (New-ParentFixture $code)
        Assert-ParentDeny $result
    } finally {
        # This fixture owns its deliberate descendant and cleans it up
        # independently of the production parent's worker handle.
        if ([IO.File]::Exists($pidPath)) {
            $child = $null
            try { $child = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidPath)); if (-not $child.HasExited) { $child.Kill() } }
            catch [ArgumentException] { }
            finally { if ($null -ne $child) { $child.Dispose() } }
        }
    }
}

Test-Case 'ASCII input beyond 1 MiB is denied before the worker can allow' {
    $oversized = $utf8.GetBytes(('x' * 1048577))
    Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture '{}') -InputBytes $oversized)
}

Test-Case 'UTF-8 input limit counts bytes rather than characters' {
    $oversized = $utf8.GetBytes((([char]0x6D4B).ToString() * 349526))
    Assert-True ($oversized.Length -gt 1048576 -and 349526 -lt 1048576) 'Incorrect multibyte fixture size.'
    Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture '{}') -InputBytes $oversized)
}

Test-Case 'Invalid UTF-8 input is denied before the worker can allow' {
    Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture '{}') -InputBytes ([byte[]]@(0xC3,0x28)))
}

Test-Case 'Input pipe that never reaches EOF is denied within the budget' {
    Assert-ParentDeny (Invoke-ParentFixture (New-OutputFixture '{}') -KeepInputOpen)
}

$sourceHashes = @()
foreach ($relative in @('hooks\pre-tool-use.ps1','tests\hook-watchdog.ps1')) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $SourceRoot $relative)))).Replace('-', '') }
    finally { $sha.Dispose() }
    $sourceHashes += [pscustomobject]@{ path=$relative; sha256=$digest }
}
$passed = @($script:results | Where-Object { $_.result -ceq 'PASS' }).Count
$failed = $script:results.Count - $passed
$report = [pscustomobject]@{ runId=$runId; powershell=$PSVersionTable.PSVersion.ToString(); shell=$ShellPath; fixtureBudgetMilliseconds=2500; total=$script:results.Count; passed=$passed; failed=$failed; sourceHashes=$sourceHashes; results=$script:results.ToArray(); processEvidence=$script:processEvidence.ToArray() }
$reportPath = Join-Path $runRoot 'results.json'
[IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 8), $utf8)
Write-Host ('TOTAL: {0}; PASS: {1}; FAIL: {2}' -f $report.total,$passed,$failed)
Write-Host ('Evidence: ' + $reportPath)
if ($failed -gt 0) { exit 1 }
exit 0
