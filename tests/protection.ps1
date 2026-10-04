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
$runId = 'protection-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PSVersionTable.PSVersion.Major, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) $runId
[void][IO.Directory]::CreateDirectory($runRoot)
$project = Join-Path $runRoot ('project with spaces ' + [char]0x6D4B + [char]0x8BD5)
$codexHome = Join-Path $runRoot 'codex-home'
$installDir = Join-Path $runRoot 'installed with spaces'
foreach ($directory in @($project, $codexHome)) { [void][IO.Directory]::CreateDirectory($directory) }
[void][IO.Directory]::CreateDirectory((Join-Path $project '.codex-safedelete'))
$utf8 = New-Object Text.UTF8Encoding($false)
$configPath = Join-Path $codexHome 'config.toml'
$hooksPath = Join-Path $codexHome 'hooks.json'
$statePath = Join-Path $installDir 'protection-state.json'
$installedCli = Join-Path $installDir 'src\safedelete.ps1'
$historyPath = Join-Path $project '.codex-safedelete\history.json'
$resultPath = Join-Path $runRoot 'results.jsonl'
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:evidence = New-Object 'System.Collections.Generic.List[object]'
$script:ready = $false
$script:hookCommand = $null
$script:installedConfig = $null
$script:installedHooks = $null
$script:recordBeforePause = $null
$script:recordForResume = $null
$originalConfig = $utf8.GetBytes("# pre-existing local configuration`r`nmodel = `"gpt-6.1-sol`"`r`n")
$originalHooks = $utf8.GetBytes('{"hooks":{"PreToolUse":[{"matcher":"^Read$","hooks":[{"type":"command","command":"Write-Output pre-existing"}]}]}}')
[IO.File]::WriteAllBytes($configPath, $originalConfig)
[IO.File]::WriteAllBytes($hooksPath, $originalHooks)
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalProcessPath = $env:Path

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-SourceHashes {
    foreach ($relative in @('install.ps1','uninstall.ps1','src\Storage.ps1','src\Commands.ps1','src\safedelete.ps1','src\InstallState.ps1','src\Protection.ps1','hooks\pre-tool-use.ps1','hooks\Trust.ps1','tests\protection.ps1')) {
        $path = Join-Path $SourceRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { [pscustomobject]@{ path=$relative; sha256=Get-Hash ([IO.File]::ReadAllBytes($path)) } }
    }
}

function Assert-Bytes([string]$Path, [byte[]]$Expected, [string]$Message) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) ($Message + ': missing file')
    Assert-True ((Get-Hash ([IO.File]::ReadAllBytes($Path))) -ceq (Get-Hash $Expected)) $Message
}

function ConvertTo-NativeArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-Process {
    param([string[]]$Arguments, [string]$InputText, [string]$WorkingDirectory = $project)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            $bytes = $utf8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) {
            throw ('Test process exceeded 120 seconds; it was not killed. PID: ' + $process.Id)
        }
        $result = [pscustomobject]@{ arguments = $Arguments; exitCode = $process.ExitCode; stdout = $stdoutTask.Result; stderr = $stderrTask.Result }
        $script:evidence.Add($result)
        return $result
    } finally { $process.Dispose() }
}

function Invoke-Cli([string]$Action, [string[]]$Paths, [string]$Id, [string]$WorkingDirectory = $project) {
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$installedCli,'-Action',$Action)
    if ($Action -notin @('off','on','status')) { $arguments += @('-ProjectRoot',$project) }
    if ($Paths) { $arguments += @('-Paths') + $Paths }
    if ($Id) { $arguments += @('-Id',$Id) }
    return Invoke-Process -Arguments $arguments -WorkingDirectory $WorkingDirectory
}

function Assert-Status([string]$Expected) {
    $result = Invoke-Cli 'status'
    Assert-True ($result.stdout -match ('(?m)^SafeDelete: ' + $Expected + '\s*$')) ('Expected status ' + $Expected + '; see process evidence')
    if ($Expected -eq 'UNKNOWN') {
        Assert-True ($result.exitCode -ne 0) 'UNKNOWN reported success'
        Assert-True ($result.stdout -match 'Configuration requires attention\.') 'UNKNOWN lacks attention message'
    } else { Assert-True ($result.exitCode -eq 0) ('Status ' + $Expected + ' failed') }
}

function Assert-ConfigurationUnchanged([byte[]]$Config = $script:installedConfig, [byte[]]$Hooks = $script:installedHooks) {
    Assert-Bytes $configPath $Config 'Protection command changed Codex configuration'
    Assert-Bytes $hooksPath $Hooks 'Protection command changed Hook configuration'
    Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $originalUserPath) 'Protection command changed user PATH'
    Assert-True ($env:Path -ceq $originalProcessPath) 'Protection command changed test-process PATH'
}

function Get-History {
    $data = [IO.File]::ReadAllText($historyPath) | ConvertFrom-Json
    if ($data.PSObject.Properties['entries']) { return @($data.entries) }
    if ($data.PSObject.Properties['history']) { return @($data.history) }
    return @($data)
}

function Invoke-RegisteredHook([string]$Command, [switch]$ExecuteReplacement) {
    $payload = @{ hook_event_name='PreToolUse'; cwd=$project; tool_name='Bash'; tool_input=@{ command=$Command } } | ConvertTo-Json -Depth 6 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:hookCommand))
    $hook = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -InputText $payload
    $decision = $null
    $execution = $null
    if ($hook.exitCode -eq 0) {
        $decision = $hook.stdout | ConvertFrom-Json
        if ($ExecuteReplacement -and $decision.PSObject.Properties['hookSpecificOutput'] -and $decision.hookSpecificOutput.PSObject.Properties['updatedInput']) {
            $replacement = [string]$decision.hookSpecificOutput.updatedInput.command
            Assert-True (-not [string]::IsNullOrWhiteSpace($replacement)) 'Hook returned an empty replacement'
            $execution = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',$replacement)
        }
    }
    return [pscustomobject]@{ process=$hook; decision=$decision; replacement=$execution }
}

function Assert-RootDenied {
    $result = Invoke-RegisteredHook 'Remove-Item -Recurse -Force .'
    Assert-True ($result.process.exitCode -eq 0) 'Registered Hook did not return an explicit blocking JSON decision'
    Assert-True ($null -ne $result.decision.PSObject.Properties['hookSpecificOutput']) 'Root delete was permitted without protection'
    Assert-True ($result.decision.hookSpecificOutput.permissionDecision -eq 'deny') 'Root delete was not denied'
}

function Save-File([string]$Name, [string]$Content) {
    $path = Join-Path $project $Name
    [IO.File]::WriteAllText($path, $Content, $utf8)
    $result = Invoke-RegisteredHook ('Remove-Item -LiteralPath ' + "'" + $Name.Replace("'", "''") + "'") -ExecuteReplacement
    Assert-True ($result.process.exitCode -eq 0) 'Registered Hook failed'
    Assert-True ($null -ne $result.replacement -and $result.replacement.exitCode -eq 0) 'Registered Hook did not execute a successful safe-delete replacement'
    Assert-True (-not (Test-Path -LiteralPath $path)) 'Safe-delete left original file present'
    $records = @(Get-History)
    $record = $records[-1]
    Assert-True ([IO.File]::ReadAllText($record.items[0].trash_path) -ceq $Content) 'Trash content did not match original file'
    return $record
}

function Invoke-Case([string]$Name, [scriptblock]$Test, [switch]$NeedsInstall) {
    $script:evidence.Clear()
    $started = [datetime]::UtcNow
    $status = 'PASS'
    $message = ''
    if ($NeedsInstall -and -not $script:ready) { $status='NOT RUN'; $message='Isolated installation did not complete.' }
    else {
        try { & $Test }
        catch { $status='FAIL'; $message=$_.Exception.Message }
    }
    $record = [pscustomobject]@{ name=$Name; status=$status; message=$message; milliseconds=[math]::Round(([datetime]::UtcNow-$started).TotalMilliseconds); evidence=@($script:evidence.ToArray()) }
    $script:results.Add($record)
    [IO.File]::AppendAllText($resultPath, ($record | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine, $utf8)
    Write-Host ('{0}: {1}{2}' -f $status,$Name,$(if ($message) { ' - ' + $message } else { '' }))
}

$initialSourceHashes = @(Get-SourceHashes)

Invoke-Case 'isolated installation creates enabled state and a single preserved native Hook' {
    $result = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate')
    Assert-True ($result.exitCode -eq 0) 'Isolated installation failed; see process evidence'
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($state.enabled -is [bool] -and $state.enabled) 'New installation is not explicitly enabled'
    $registered = [IO.File]::ReadAllText($hooksPath) | ConvertFrom-Json
    $safe = @($registered.hooks.PreToolUse | Where-Object { $_.matcher -eq '^(Bash|apply_patch)$' })
    Assert-True ($safe.Count -eq 1 -and $safe[0].hooks.Count -eq 1) 'SafeDelete Hook is missing or duplicated'
    Assert-True (@($registered.hooks.PreToolUse | Where-Object { $_.matcher -eq '^Read$' }).Count -eq 1) 'Existing unrelated Hook was not preserved'
    $script:hookCommand = $safe[0].hooks[0].command
    $script:installedConfig = [IO.File]::ReadAllBytes($configPath)
    $script:installedHooks = [IO.File]::ReadAllBytes($hooksPath)
    $script:ready = $true
    Assert-ConfigurationUnchanged
}

Invoke-Case 'status is ON after installation and installed CMD exposes the command' -NeedsInstall {
    Assert-Status 'ON'
    $shim = Join-Path $installDir 'safedelete.cmd'
    $scriptText = "& '" + $shim.Replace("'", "''") + "' status; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    $result = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: ON') 'Installed safedelete status CMD failed'
    Assert-RootDenied
}

Invoke-Case 'status off and on from a project subdirectory reflect the same real installation state' -NeedsInstall {
    $child = Join-Path $project ('nested with spaces ' + [char]0x4E2D + [char]0x6587)
    [void][IO.Directory]::CreateDirectory($child)
    $result = Invoke-Cli 'status' -WorkingDirectory $child
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: ON') 'Subdirectory status did not detect protection ON'
    $result = Invoke-Cli 'off' -WorkingDirectory $child
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: OFF') 'Subdirectory off failed'
    $result = Invoke-Cli 'status' -WorkingDirectory $child
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: OFF') 'Subdirectory status did not detect protection OFF'
    Assert-Status 'OFF'
    $result = Invoke-Cli 'on' -WorkingDirectory $child
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: ON') 'Subdirectory on failed'
    $result = Invoke-Cli 'status' -WorkingDirectory $child
    Assert-True ($result.exitCode -eq 0 -and $result.stdout -match 'SafeDelete: ON') 'Subdirectory status did not detect protection ON after resume'
    Assert-Status 'ON'
    Assert-RootDenied
    Assert-ConfigurationUnchanged
}

Invoke-Case 'ON Hook stores existing recovery history before pause' -NeedsInstall {
    $script:recordBeforePause = Save-File 'before-pause.txt' 'retained before pause'
}

Invoke-Case 'off shows OFF and preserves Hook configuration PATH trash and history' -NeedsInstall {
    $before = [IO.File]::ReadAllBytes($historyPath)
    $result = Invoke-Cli 'off'
    Assert-True ($result.exitCode -eq 0) 'off failed'
    Assert-Status 'OFF'
    Assert-Bytes $historyPath $before 'off changed existing recovery history'
    Assert-True (Test-Path -LiteralPath $script:recordBeforePause.items[0].trash_path -PathType Leaf) 'off removed existing trash'
    Assert-ConfigurationUnchanged
}

Invoke-Case 'repeated off remains OFF without configuration or history changes' -NeedsInstall {
    $before = [IO.File]::ReadAllBytes($historyPath)
    Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'Repeated off failed'
    Assert-Status 'OFF'
    Assert-Bytes $historyPath $before 'Repeated off changed history'
    Assert-ConfigurationUnchanged
}

Invoke-Case 'OFF registered Hook allows actual deletion of one synthetic file' -NeedsInstall {
    $path = Join-Path $project 'off-only-synthetic.txt'
    [IO.File]::WriteAllText($path, 'only this disposable fixture is permanently deleted', $utf8)
    $before = [IO.File]::ReadAllBytes($historyPath)
    $hook = Invoke-RegisteredHook 'Remove-Item -LiteralPath off-only-synthetic.txt'
    Assert-True ($hook.process.exitCode -eq 0 -and @($hook.decision.PSObject.Properties).Count -eq 0) 'OFF Hook did not return an empty allow decision'
    $deleted = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command','Remove-Item -LiteralPath off-only-synthetic.txt')
    Assert-True ($deleted.exitCode -eq 0 -and -not (Test-Path -LiteralPath $path)) 'OFF synthetic delete did not execute'
    Assert-Bytes $historyPath $before 'OFF permanent deletion incorrectly changed recovery history'
}

Invoke-Case 'OFF list and restore retain access to pre-pause recovery records' -NeedsInstall {
    Assert-True ($null -ne $script:recordBeforePause) 'Pre-pause record is unavailable'
    $listing = Invoke-Cli 'list'
    Assert-True ($listing.exitCode -eq 0 -and $listing.stdout.Contains($script:recordBeforePause.id)) 'OFF list lost the existing record'
    Assert-True ((Invoke-Cli 'restore' -Id $script:recordBeforePause.id).exitCode -eq 0) 'OFF restore failed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $project 'before-pause.txt')) -ceq 'retained before pause') 'OFF restore changed recovered content'
    Assert-Status 'OFF'
}

Invoke-Case 'on returns ON without modifying installed configuration or PATH' -NeedsInstall {
    $before = [IO.File]::ReadAllBytes($historyPath)
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'on failed'
    Assert-Status 'ON'
    Assert-RootDenied
    Assert-Bytes $historyPath $before 'on changed history'
    Assert-ConfigurationUnchanged
}

Invoke-Case 'repeated on does not duplicate Hook PATH or configuration' -NeedsInstall {
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'Repeated on failed'
    Assert-Status 'ON'
    Assert-ConfigurationUnchanged
    $registered = [IO.File]::ReadAllText($hooksPath) | ConvertFrom-Json
    Assert-True (@($registered.hooks.PreToolUse | Where-Object { $_.matcher -eq '^(Bash|apply_patch)$' }).Count -eq 1) 'Repeated on duplicated the Hook'
}

Invoke-Case 'OFF undo can restore an existing recoverable deletion' -NeedsInstall {
    $record = Save-File 'off-undo.txt' 'undo remains available when paused'
    Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'off before undo failed'
    Assert-True ((Invoke-Cli 'undo').exitCode -eq 0) 'OFF undo failed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $project 'off-undo.txt')) -ceq 'undo remains available when paused') 'OFF undo did not restore exact content'
    Assert-Status 'OFF'
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'on after OFF undo failed'
}

Invoke-Case 'pause then resume preserves existing payload for undo' -NeedsInstall {
    $script:recordForResume = Save-File 'resume-undo.txt' 'undo after resume preserves exact bytes'
    $before = [IO.File]::ReadAllBytes($historyPath)
    Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'off before resume failed'
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'resume failed'
    Assert-Bytes $historyPath $before 'Pause/resume changed history'
    Assert-True ((Invoke-Cli 'undo').exitCode -eq 0) 'Undo after resume failed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $project 'resume-undo.txt')) -ceq 'undo after resume preserves exact bytes') 'Undo after resume did not restore exact content'
    Assert-ConfigurationUnchanged
}

Invoke-Case 'pause and resume preserve later unrelated config and Hook edits byte for byte' -NeedsInstall {
    $editedConfig = $utf8.GetBytes($utf8.GetString($script:installedConfig) + "`r`n# unrelated user comment added after installation`r`n")
    $hookObject = $utf8.GetString($script:installedHooks) | ConvertFrom-Json
    $hookObject.hooks.PreToolUse += [pscustomobject]@{ matcher='^Write$'; hooks=@([pscustomobject]@{ type='command'; command='Write-Output later-unrelated-hook' }) }
    $editedHooks = $utf8.GetBytes(($hookObject | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllBytes($configPath, $editedConfig)
    [IO.File]::WriteAllBytes($hooksPath, $editedHooks)
    try {
        Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'off with unrelated edits failed'
        Assert-Status 'OFF'
        Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'on with unrelated edits failed'
        Assert-Status 'ON'
        Assert-ConfigurationUnchanged $editedConfig $editedHooks
    } finally {
        [IO.File]::WriteAllBytes($configPath, $script:installedConfig)
        [IO.File]::WriteAllBytes($hooksPath, $script:installedHooks)
    }
}

Invoke-Case 'corrupt local protection state reports UNKNOWN and fails closed' -NeedsInstall {
    [IO.File]::WriteAllText($statePath, '{not-valid-json', $utf8)
    Assert-Status 'UNKNOWN'
    Assert-RootDenied
    Assert-ConfigurationUnchanged
}

Invoke-Case 'on refuses corrupt own state without changing Codex or recovery data' -NeedsInstall {
    $before = [IO.File]::ReadAllBytes($historyPath)
    $badState = [IO.File]::ReadAllBytes($statePath)
    try {
        $result = Invoke-Cli 'on'
        Assert-True ($result.exitCode -ne 0 -and $result.stdout -match 'SafeDelete: UNKNOWN') 'on accepted corrupt own state'
        Assert-Status 'UNKNOWN'
        Assert-Bytes $statePath $badState 'on silently changed corrupt own state'
        Assert-Bytes $historyPath $before 'Rejected state change altered history'
        Assert-ConfigurationUnchanged
    } finally { [IO.File]::WriteAllText($statePath, '{"enabled":true}', $utf8) }
    Assert-Status 'ON'
}

Invoke-Case 'invalid enabled value cannot silently disable the Hook' -NeedsInstall {
    [IO.File]::WriteAllText($statePath, '{"enabled":"false"}', $utf8)
    Assert-Status 'UNKNOWN'
    Assert-RootDenied
    try {
        Assert-True ((Invoke-Cli 'on').exitCode -ne 0) 'on accepted invalid enabled value'
    } finally { [IO.File]::WriteAllText($statePath, '{"enabled":true}', $utf8) }
}

Invoke-Case 'missing own state reports UNKNOWN while root deletion remains denied' -NeedsInstall {
    [IO.File]::Delete($statePath)
    Assert-Status 'UNKNOWN'
    Assert-RootDenied
    Assert-ConfigurationUnchanged
}

Invoke-Case 'on recreates missing own state and verifies ON' -NeedsInstall {
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'on could not recreate missing state'
    Assert-Status 'ON'
    Assert-ConfigurationUnchanged
}

Invoke-Case 'disabled native Codex Hook support reports UNKNOWN instead of ON' -NeedsInstall {
    $text = $utf8.GetString($script:installedConfig)
    $hits = [regex]::Matches($text, '(?m)^hooks\s*=\s*true\s*$')
    Assert-True ($hits.Count -eq 1) 'Expected one installed features.hooks=true setting'
    $modified = [regex]::Replace($text, '(?m)^hooks\s*=\s*true\s*$', 'hooks = false')
    [IO.File]::WriteAllText($configPath, $modified, $utf8)
    try { Assert-Status 'UNKNOWN'; Assert-RootDenied }
    finally { [IO.File]::WriteAllBytes($configPath, $script:installedConfig) }
    Assert-Status 'ON'
}

Invoke-Case 'untrusted native Hook reports UNKNOWN instead of ON' -NeedsInstall {
    $text = $utf8.GetString($script:installedConfig)
    $hits = [regex]::Matches($text, '(?m)^trusted_hash\s*=\s*"[^"]+"\s*$')
    Assert-True ($hits.Count -eq 1) 'Expected one native SafeDelete trusted_hash setting'
    $modified = [regex]::Replace($text, '(?m)^trusted_hash\s*=\s*"[^"]+"\s*$', ('trusted_hash = "' + ('0' * 64) + '"'))
    [IO.File]::WriteAllText($configPath, $modified, $utf8)
    try { Assert-Status 'UNKNOWN'; Assert-RootDenied }
    finally { [IO.File]::WriteAllBytes($configPath, $script:installedConfig) }
    Assert-Status 'ON'
}

Invoke-Case 'a changed registered Hook command reports UNKNOWN without rewriting user configuration' -NeedsInstall {
    $hookObject = $utf8.GetString($script:installedHooks) | ConvertFrom-Json
    $safe = @($hookObject.hooks.PreToolUse | Where-Object { $_.matcher -eq '^(Bash|apply_patch)$' })
    $safe[0].hooks[0].command += ' '
    $modified = $utf8.GetBytes(($hookObject | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllBytes($hooksPath, $modified)
    try {
        Assert-Status 'UNKNOWN'
        Assert-True ((Invoke-Cli 'on').exitCode -ne 0) 'on accepted a changed registered Hook command'
        Assert-ConfigurationUnchanged $script:installedConfig $modified
    } finally { [IO.File]::WriteAllBytes($hooksPath, $script:installedHooks) }
    Assert-Status 'ON'
}

Invoke-Case 'a changed registered Hook matcher reports UNKNOWN without rewriting user configuration' -NeedsInstall {
    $hookObject = $utf8.GetString($script:installedHooks) | ConvertFrom-Json
    $safe = @($hookObject.hooks.PreToolUse | Where-Object { $_.matcher -eq '^(Bash|apply_patch)$' })
    $safe[0].matcher = '^Bash$'
    $modified = $utf8.GetBytes(($hookObject | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllBytes($hooksPath, $modified)
    try {
        Assert-Status 'UNKNOWN'
        Assert-True ((Invoke-Cli 'off').exitCode -ne 0) 'off accepted a changed registered Hook matcher'
        Assert-ConfigurationUnchanged $script:installedConfig $modified
    } finally { [IO.File]::WriteAllBytes($hooksPath, $script:installedHooks) }
    Assert-Status 'ON'
}

Invoke-Case 'OFF flag with a missing registered Hook reports UNKNOWN and on refuses to recreate configuration' -NeedsInstall {
    Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'off before missing Hook fixture failed'
    $pausedState = [IO.File]::ReadAllBytes($statePath)
    $hookObject = $utf8.GetString($script:installedHooks) | ConvertFrom-Json
    $hookObject.hooks.PreToolUse = @($hookObject.hooks.PreToolUse | Where-Object { $_.matcher -ne '^(Bash|apply_patch)$' })
    $modified = $utf8.GetBytes(($hookObject | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllBytes($hooksPath, $modified)
    try {
        Assert-Status 'UNKNOWN'
        Assert-True ((Invoke-Cli 'on').exitCode -ne 0) 'on recreated a missing Hook instead of reporting UNKNOWN'
        Assert-Bytes $statePath $pausedState 'Rejected on changed paused state'
        Assert-ConfigurationUnchanged $script:installedConfig $modified
    } finally { [IO.File]::WriteAllBytes($hooksPath, $script:installedHooks) }
    Assert-Status 'OFF'
    Assert-True ((Invoke-Cli 'on').exitCode -eq 0) 'on after restoring Hook fixture failed'
    Assert-Status 'ON'
}

foreach ($relative in @('src\Storage.ps1','src\Protection.ps1')) {
    Invoke-Case ('missing installed ' + $relative + ' reports UNKNOWN') -NeedsInstall {
        $installedPath = [IO.Path]::GetFullPath((Join-Path $installDir $relative))
        $savedPath = [IO.Path]::GetFullPath(($installedPath + '.test-backup'))
        $allowedRoot = [IO.Path]::GetFullPath($installDir).TrimEnd([char[]]'\/') + '\'
        Assert-True ($installedPath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and $savedPath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) 'Missing-file fixture escapes the isolated installation'
        [IO.File]::Move($installedPath, $savedPath)
        try {
            Assert-Status 'UNKNOWN'
            Assert-ConfigurationUnchanged
        } finally { [IO.File]::Move($savedPath, $installedPath) }
        Assert-Status 'ON'
    }
}

Invoke-Case 'uninstall while paused restores original config Hooks and PATH and preserves recovery history' -NeedsInstall {
    Assert-True ((Invoke-Cli 'off').exitCode -eq 0) 'Pause before uninstall failed'
    $before = [IO.File]::ReadAllBytes($historyPath)
    $result = Invoke-Process -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate')
    Assert-True ($result.exitCode -eq 0) 'Uninstall while paused failed; see process evidence'
    Assert-Bytes $configPath $originalConfig 'Uninstall did not restore original config byte for byte'
    Assert-Bytes $hooksPath $originalHooks 'Uninstall did not restore original Hooks byte for byte'
    Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Uninstall left installed files or own state behind'
    Assert-Bytes $historyPath $before 'Uninstall changed recovery history'
    Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $originalUserPath) 'Uninstall changed original user PATH'
    Assert-True ($env:Path -ceq $originalProcessPath) 'Uninstall changed parent-process PATH'
    Assert-True (Test-Path -LiteralPath (Join-Path $project '.codex-safedelete\trash') -PathType Container) 'Uninstall removed the recoverable store'
    $script:ready = $false
}

$sourceHashes = @(Get-SourceHashes)
Invoke-Case 'source files remained unchanged during the complete test run' {
    Assert-True ($initialSourceHashes.Count -eq $sourceHashes.Count) 'Source file set changed during tests'
    foreach ($initial in $initialSourceHashes) {
        $current = @($sourceHashes | Where-Object { $_.path -ceq $initial.path })
        Assert-True ($current.Count -eq 1 -and $current[0].sha256 -ceq $initial.sha256) ('Source changed during tests: ' + $initial.path)
    }
}
$passed = @($script:results | Where-Object { $_.status -eq 'PASS' }).Count
$failed = @($script:results | Where-Object { $_.status -eq 'FAIL' }).Count
$notRun = @($script:results | Where-Object { $_.status -eq 'NOT RUN' }).Count
$summary = [pscustomobject]@{ shell=$ShellPath; powershell=$PSVersionTable.PSVersion.ToString(); runId=$runId; total=$script:results.Count; passed=$passed; failed=$failed; notRun=$notRun; evidence=$resultPath; fixtures=$runRoot; installation_remaining=$script:ready; user_path_unchanged=([Environment]::GetEnvironmentVariable('Path','User') -ceq $originalUserPath); sourceHashes=$sourceHashes; initialSourceHashes=$initialSourceHashes }
[IO.File]::WriteAllText((Join-Path $runRoot 'summary.json'), ($summary | ConvertTo-Json -Depth 8), $utf8)
Write-Host ('TOTAL: {0}; PASS: {1}; FAIL: {2}; NOT RUN: {3}' -f $summary.total,$passed,$failed,$notRun)
Write-Host ('Evidence: ' + $resultPath)
if ($failed -gt 0 -or $notRun -gt 0) { exit 1 }
exit 0
