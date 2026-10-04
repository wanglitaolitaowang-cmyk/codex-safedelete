# Isolated source-Hook requests; no installation or global protection changes.
[CmdletBinding()]
param([string]$EvidenceRoot, [string]$ShellPath = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$project = Split-Path $PSScriptRoot -Parent
$cli = Join-Path $project 'src\safedelete.ps1'
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $PSScriptRoot '.work' }
$run = 'shell-compatibility-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$evidence = [IO.Path]::GetFullPath((Join-Path $EvidenceRoot $run))
$null = [IO.Directory]::CreateDirectory($evidence)
$results = New-Object 'System.Collections.Generic.List[object]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Invoke-SourceHook {
    param([string]$Root, [string]$Command, [string]$Shell)
    $inputData = @{ command = $Command; workdir = $Root }
    if ($Shell) { $inputData.shell = $Shell }
    $request = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; cwd = $Root; tool_input = $inputData }
    $payload = ConvertTo-Json -InputObject $request -Depth 5 -Compress
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $start.Arguments = (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,'-Action','hook') | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Source Hook timed out.' }
        $stdout = $stdoutTask.Result; $stderr = $stderrTask.Result
        [IO.File]::WriteAllText((Join-Path $Root 'hook-input.json'), $payload, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $Root 'hook-stdout.txt'), $stdout, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $Root 'hook-stderr.txt'), $stderr, (New-Object Text.UTF8Encoding($false)))
        Assert-True ($process.ExitCode -eq 0) ('Hook exited ' + $process.ExitCode + '; see fixture stderr.')
        Assert-True (-not [string]::IsNullOrWhiteSpace($stdout)) 'Hook produced no complete JSON response.'
        try { return ConvertFrom-Json -InputObject $stdout -ErrorAction Stop }
        catch { throw 'Hook output is invalid JSON; see complete fixture stdout.' }
    } finally { $process.Dispose() }
}

function Invoke-FixturePowerShell {
    param([string]$Root, [string]$Script, [string]$EvidenceName)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
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
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Fixture PowerShell command timed out.' }
        [IO.File]::WriteAllText((Join-Path $Root ($EvidenceName + '-stdout.txt')), $stdoutTask.Result, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $Root ($EvidenceName + '-stderr.txt')), $stderrTask.Result, (New-Object Text.UTF8Encoding($false)))
        Assert-True ($process.ExitCode -eq 0) ('Fixture command exited ' + $process.ExitCode + '; see complete evidence.')
    } finally { $process.Dispose() }
}

$cases = @(
    @{ name='cmd deletion denied'; shell='cmd'; command='del payload.txt'; expected='deny' }
    @{ name='bash deletion denied'; shell='bash'; command='rm payload.txt'; expected='deny' }
    @{ name='sh deletion denied'; shell='sh'; command='rm payload.txt'; expected='deny' }
    @{ name='wsl deletion denied'; shell='wsl'; command='rm payload.txt'; expected='deny' }
    @{ name='quoted bash command name denied'; shell='bash'; command='"rm" payload.txt'; expected='deny' }
    @{ name='escaped bash command name denied'; shell='bash'; command='r\m payload.txt'; expected='deny' }
    @{ name='bash backslash target denied'; shell='bash'; command='rm folder\file.txt'; expected='deny' }
    @{ name='nested quoted bash command name denied'; command='bash -c ''"rm" payload.txt'''; expected='deny' }
    @{ name='nested escaped bash command name denied'; command='bash -c ''r\m payload.txt'''; expected='deny' }
    @{ name='nested bash backslash target denied'; command='bash -c ''rm folder\file.txt'''; expected='deny' }
    @{ name='unknown explicit shell denied'; shell='zsh'; command='"rm" payload.txt'; expected='deny' }
    @{ name='bash substitution denied'; shell='bash'; command='echo $(rm payload.txt)'; expected='deny' }
    @{ name='cmd variable denied'; shell='cmd'; command='echo %DELETE_COMMAND%'; expected='deny' }
    @{ name='bash mixed work denied'; shell='bash'; command='npm test; rm payload.txt'; expected='deny' }
    @{ name='bash errexit npm test allowed'; command='bash -e -c "npm test"'; expected='allow' }
    @{ name='wsl exec git status allowed'; command='wsl -e git status'; expected='allow' }
    @{ name='cmd inner echo e allowed'; command='cmd /c "echo -e"'; expected='allow' }
    @{ name='sh combined ec echo allowed'; command='sh -ec "echo -e"'; expected='allow' }
    @{ name='bash login git status allowed'; command='bash -lc "git status"'; expected='allow' }
    @{ name='explicit bash npm test allowed'; shell='bash'; command='npm test'; expected='allow' }
    @{ name='explicit cmd git status allowed'; shell='cmd'; command='git status --short'; expected='allow' }
    @{ name='default git status allowed'; command='git status'; expected='allow' }
    @{ name='missing metadata quoted command denied'; command='"rm" payload.txt'; expected='deny' }
    @{ name='missing metadata escaped command denied'; command='r\m payload.txt'; expected='deny' }
    @{ name='missing metadata ambiguous rm backslash target denied'; command='rm folder\file.txt'; expected='deny' }
    @{ name='missing metadata absolute Windows executable allowed'; command=('& "' + $ShellPath + '" -NoProfile -Command "echo safe"'); expected='allow' }
    @{ name='powershell encoded denied'; command='powershell -EncodedCommand ZQBjAGgAbwAgAGgAaQA='; expected='deny' }
    @{ name='pwsh encoded abbreviation denied'; command='pwsh -ec ZQBjAGgAbwAgAGgAaQA='; expected='deny' }
    @{ name='powershell file denied'; command='powershell -File delete.ps1'; expected='deny' }
    @{ name='powershell variable path denied'; command='powershell -Command "Remove-Item $target"'; expected='deny' }
    @{ name='powershell variable command denied'; command='powershell -Command $deleteCommand'; expected='deny' }
    @{ name='powershell inner echo e allowed'; command='powershell -Command "echo -e"'; expected='allow' }
    @{ name='pwsh startup directory change denied'; command='pwsh -NoProfile -WorkingDirectory folder -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='pwsh startup wd abbreviation denied'; command='pwsh -NoProfile -wd folder -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='pwsh startup wo abbreviation denied'; command='pwsh -NoProfile -wo folder -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='pwsh startup wor abbreviation denied'; command='pwsh -NoProfile -wor folder -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='PowerShell wrapper profile must be disabled for deletion'; command='powershell -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='dynamic PowerShell startup parameter denied'; command='pwsh -NoProfile -ExecutionPolicy $policy -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='unknown PowerShell startup parameter denied'; command='pwsh -NoProfile -SettingsFile settings.json -Command "Remove-Item payload.txt"'; expected='deny' }
    @{ name='wsl destructive startup option denied'; command='wsl --unregister fixture -e git status'; expected='deny' }
    @{ name='bash startup script option denied'; command='bash --init-file profile -c "npm test"'; expected='deny' }
    @{ name='default Bash abstraction still rewrites PowerShell delete'; command='Remove-Item -LiteralPath payload.txt'; expected='rewrite' }
    @{ name='explicit PowerShell rm deletes safely and undoes'; shell=$ShellPath; command='rm payload.txt'; expected='rewrite'; execute=$true }
    @{ name='nested pwsh literal delete rewrites'; command='pwsh -NoProfile -Command "Remove-Item payload.txt"'; expected='rewrite' }
)

for ($index = 0; $index -lt $cases.Count; $index++) {
    $case = $cases[$index]
    $root = Join-Path $evidence ($index.ToString('D2'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $root '.git'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $root 'folder'))
    $fixtures = @{
        'payload.txt' = [byte[]]@(0, 255, 128, 13, 10, 65)
        'folder\file.txt' = [byte[]]@(1, 2, 3, 4)
        'folder\payload.txt' = [byte[]]@(4, 3, 2, 1)
        'folderfile.txt' = [byte[]]@(9, 8, 7, 6)
    }
    foreach ($relative in $fixtures.Keys) { [IO.File]::WriteAllBytes((Join-Path $root $relative), $fixtures[$relative]) }
    try {
        $shell = $null
        if ($case.ContainsKey('shell')) { $shell = $case.shell }
        $response = Invoke-SourceHook $root $case.command $shell
        $decision = $response.PSObject.Properties['hookSpecificOutput']
        switch ($case.expected) {
            'allow' { Assert-True ($null -eq $decision) 'A benign command was denied or rewritten.' }
            'deny' {
                Assert-True ($null -ne $decision -and $decision.Value.permissionDecision -eq 'deny') 'Unsafe command was not denied.'
                Assert-True ($null -eq $decision.Value.PSObject.Properties['updatedInput']) 'Denied command unexpectedly gained a replacement.'
            }
            'rewrite' {
                Assert-True ($null -ne $decision -and $decision.Value.permissionDecision -eq 'allow') 'PowerShell deletion was not intercepted.'
                Assert-True ($null -ne $decision.Value.PSObject.Properties['updatedInput'] -and $decision.Value.updatedInput.command.Contains('-Action delete')) 'PowerShell deletion did not gain a SafeDelete replacement.'
            }
        }
        foreach ($relative in $fixtures.Keys) {
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $relative))) -ceq [Convert]::ToBase64String($fixtures[$relative])) ('Source Hook changed fixture bytes: ' + $relative)
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Hook created a deletion record before executing its replacement.'
        if ($case.ContainsKey('execute') -and $case.execute) {
            Invoke-FixturePowerShell $root $decision.Value.updatedInput.command 'delete'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'payload.txt'))) 'Explicit PowerShell rm did not move its intended payload.'
            $historyPath = Join-Path $root '.codex-safedelete\history.json'
            $history = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($historyPath)) -ErrorAction Stop
            Assert-True (@($history).Count -eq 1 -and @($history)[0].status -eq 'active') 'Explicit PowerShell rm did not persist one active record.'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes(@($history)[0].items[0].trash_path)) -ceq [Convert]::ToBase64String($fixtures['payload.txt'])) 'Safe deletion changed binary payload bytes.'
            $undo = '& ''' + $cli.Replace("'", "''") + ''' -Action undo -ProjectRoot ''' + $root.Replace("'", "''") + ''''
            Invoke-FixturePowerShell $root $undo 'undo'
            foreach ($relative in $fixtures.Keys) {
                Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $relative))) -ceq [Convert]::ToBase64String($fixtures[$relative])) ('Deletion/undo changed fixture bytes: ' + $relative)
            }
            $history = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($historyPath)) -ErrorAction Stop
            Assert-True (@($history)[0].status -eq 'restored') 'Undo did not complete the explicit PowerShell deletion record.'
        }
        $results.Add([pscustomobject]@{ name=$case.name; result='PASS'; error=$null; expected=$case.expected; fixture=$root })
    } catch {
        $results.Add([pscustomobject]@{ name=$case.name; result='FAIL'; error=$_.Exception.Message; expected=$case.expected; fixture=$root })
    }
}
$passed = @($results | Where-Object { $_.result -eq 'PASS' }).Count
$failed = $results.Count - $passed
$reportPath = Join-Path $evidence 'report.json'
$report = [pscustomobject]@{
    result=$(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); runtime=$PSVersionTable.PSVersion.ToString()
    tested_at=[DateTime]::UtcNow.ToString('o'); total=$results.Count; passed=$passed; failed=$failed
    tests=@($results.ToArray()); fixtures=$evidence
}
[IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 5), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ result=$report.result; runtime=$report.runtime; total=$report.total; passed=$passed; failed=$failed; report=$reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
