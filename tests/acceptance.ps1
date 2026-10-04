[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ArtifactRoot,
    [string]$ShellPath = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName),
    [string]$NpmCliPath,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path $PSScriptRoot '.work' }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$cli = Join-Path $SourceRoot 'src\safedelete.ps1'
$commands = Join-Path $SourceRoot 'src\Commands.ps1'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "Missing CLI: $cli" }
if (-not (Test-Path -LiteralPath $commands -PathType Leaf)) { throw "Missing parser: $commands" }
. $commands
. (Join-Path $SourceRoot 'src\InstallState.ps1')

$runId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PSVersionTable.PSVersion.Major, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) $runId
[void][IO.Directory]::CreateDirectory($runRoot)
$resultPath = Join-Path $runRoot 'results.jsonl'
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:evidence = New-Object 'System.Collections.Generic.List[object]'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ProgramHashes {
    foreach ($relative in @('install.ps1', 'uninstall.ps1', 'src\Storage.ps1', 'src\Commands.ps1', 'src\safedelete.ps1', 'src\InstallState.ps1', 'src\Protection.ps1', 'hooks\pre-tool-use.ps1', 'hooks\Trust.ps1', 'tests\acceptance.ps1')) {
        $stream = [IO.File]::OpenRead((Join-Path $SourceRoot $relative))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { [pscustomobject]@{ path = $relative; sha256 = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } }
        finally { $sha.Dispose(); $stream.Dispose() }
    }
}

function New-Fixture([string]$Name) {
    $path = Join-Path $runRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    [void][IO.Directory]::CreateDirectory((Join-Path $path '.codex-safedelete'))
    return $path
}

function New-InstallSourceFixture([string]$Root) {
    $copy = Join-Path $Root 'source'
    foreach ($relative in (@('install.ps1') + @(Get-SafeDeleteInstallManifest))) {
        if ($relative -eq 'safedelete.cmd') { continue }
        $target = Join-Path $copy $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $relative), $target)
    }
    return $copy
}

function New-RolledBackFixture([string]$Name, [bool]$ExistingConfiguration) {
    $root = New-Fixture $Name
    $codexHome = Join-Path $root 'codex-home'
    $installDir = Join-Path $root 'installed'
    [void][IO.Directory]::CreateDirectory($codexHome)
    [void][IO.Directory]::CreateDirectory((Join-Path $installDir 'backup'))
    [void][IO.Directory]::CreateDirectory((Join-Path $installDir 'src'))
    $files = @('uninstall.ps1','src\InstallState.ps1')
    foreach ($relative in $files) { [IO.File]::Copy((Join-Path $SourceRoot $relative), (Join-Path $installDir $relative)) }
    # Trap PATH restoration in this isolated copy; a regression must never write
    # the real User PATH, even when the recorded original differs from it.
    $module = Join-Path $installDir 'src\InstallState.ps1'
    $moduleText = [IO.File]::ReadAllText($module)
    $pathWrite = "[Environment]::SetEnvironmentVariable('Path', `$State.original_user_path, 'User')"
    Assert-True ($moduleText.Contains($pathWrite)) 'Rollback fixture could not guard the User PATH write'
    [IO.File]::WriteAllText($module, $moduleText.Replace($pathWrite, "throw 'Rollback cleanup attempted to restore User PATH.'"), (New-Object Text.UTF8Encoding($false)))
    $snapshots = @()
    foreach ($name in @('config.toml','hooks.json')) {
        $path = Join-Path $codexHome $name
        if ($ExistingConfiguration) {
            $content = if ($name -eq 'config.toml') { "# original configuration`r`n" } else { '{"hooks":{}}' }
            [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::Copy($path, (Join-Path $installDir ('backup\' + $name)))
        }
        $snapshots += [pscustomobject]@{ name=$name; path=$path; existed=$ExistingConfiguration; original_hash=(Get-SafeDeleteFileHash $path); installed_hash=$null }
    }
    $state = [pscustomobject]@{
        version=1; phase='rolled-back'; install_dir=$installDir; codex_home=$codexHome
        hook_command=''; snapshots=$snapshots; files=$files; path_updated=$true
        original_user_path='SAFEDELETE_TEST_OLD_PATH'; original_process_path='SAFEDELETE_TEST_OLD_PROCESS_PATH'
        installed_user_path='SAFEDELETE_TEST_INSTALLED_PATH'
    }
    Write-SafeDeleteJson (Join-Path $installDir 'install-state.json') $state
    return [pscustomobject]@{ root=$root; codexHome=$codexHome; installDir=$installDir }
}

function ConvertTo-NativeArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-Process {
    param([string]$Program, [string[]]$Arguments, [string]$InputText, [string]$WorkingDirectory = $SourceRoot)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Program
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $WorkingDirectory
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
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            # .NET Framework lacks StandardInputEncoding. Write exact UTF-8 bytes.
            $inputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw "Process timed out after 60 seconds: $Program"
        }
        $result = [pscustomobject]@{
            program = $Program
            arguments = $Arguments
            exitCode = $process.ExitCode
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
        }
        $script:evidence.Add($result)
        return $result
    }
    finally { $process.Dispose() }
}

function Invoke-Cli {
    param([string]$Action, [string]$Root, [string[]]$Paths, [string]$Id, [string]$Command)
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cli, '-Action', $Action, '-ProjectRoot', $Root)
    if ($Paths) { $arguments += @('-Paths') + $Paths }
    if ($Id) { $arguments += @('-Id', $Id) }
    if ($Command) { $arguments += @('-Command', $Command) }
    return Invoke-Process -Program $ShellPath -Arguments $arguments -WorkingDirectory $Root
}

function Get-PlainProcessError([string]$Message) {
    # Keep the original stderr in process evidence. Remove only display markup
    # from this derived text so PowerShell 7 wrapping does not break assertions.
    $plain = $Message -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    $lines = @($plain -split '\r?\n' | ForEach-Object { $_ -replace '^\s*(?:\d+\s*)?\|\s*', '' })
    return (($lines -join ' ') -replace '\s+', ' ').Trim()
}

# Keep the hook protocol in one helper so tests follow the installed Codex protocol.
function Complete-ToolHook($Result, [string]$WorkingDirectory) {
    $execution = $null
    if ($Result.exitCode -eq 0) {
        $decision = $Result.stdout | ConvertFrom-Json
        if ($decision.PSObject.Properties['hookSpecificOutput'] -and $decision.hookSpecificOutput.PSObject.Properties['updatedInput']) {
            $replacement = $decision.hookSpecificOutput.updatedInput.command
            Assert-True (-not [string]::IsNullOrWhiteSpace($replacement)) 'Hook supplied an empty replacement command'
            $execution = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $replacement) -WorkingDirectory $WorkingDirectory
        }
    }
    $Result | Add-Member -NotePropertyName replacementExecution -NotePropertyValue $execution
    return $Result
}

function Invoke-ToolHook([string]$Root, [string]$Command, [string]$WorkingDirectory = $Root) {
    $payload = @{
        hook_event_name = 'PreToolUse'
        cwd = $Root
        tool_name = 'Bash'
        tool_input = @{ command = $Command }
    } | ConvertTo-Json -Depth 8 -Compress
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cli, '-Action', 'hook') -InputText $payload -WorkingDirectory $Root
    return Complete-ToolHook $result $WorkingDirectory
}

function Invoke-PatchHook([string]$Root, $ToolInput) {
    $payload = @{ hook_event_name = 'PreToolUse'; cwd = $Root; tool_name = 'apply_patch'; tool_input = $ToolInput } | ConvertTo-Json -Depth 8 -Compress
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'hooks\pre-tool-use.ps1')) -InputText $payload -WorkingDirectory $Root
    return Complete-ToolHook $result $Root
}

function Get-History([string]$Root) {
    $path = Join-Path $Root '.codex-safedelete\history.json'
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) 'history.json was not created'
    $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($null -ne $data -and $data.PSObject.Properties['entries']) { return @($data.entries) }
    if ($null -ne $data -and $data.PSObject.Properties['history']) { return @($data.history) }
    return @($data)
}

function Get-Field($Record, [string[]]$Names) {
    foreach ($name in $Names) {
        if ($Record.PSObject.Properties[$name]) { return $Record.$name }
    }
    return $null
}

function Get-Record([string]$Root, [string]$OriginalPath) {
    $matches = @()
    foreach ($record in @(Get-History $Root)) {
        if ($record.PSObject.Properties['items']) {
            foreach ($item in @($record.items)) {
                if ((Get-Field $item @('originalPath', 'original_path')) -eq $OriginalPath) {
                    $matches += [pscustomobject]@{
                        id = Get-Field $record @('id')
                        deleted_at = Get-Field $record @('deletedAt', 'deleted_at', 'timestamp')
                        command = Get-Field $record @('command', 'triggerCommand')
                        original_path = Get-Field $item @('originalPath', 'original_path')
                        trash_path = Get-Field $item @('trashPath', 'trash_path', 'restorePath', 'restore_path')
                        name = Get-Field $item @('name')
                    }
                }
            }
        }
        elseif ((Get-Field $record @('originalPath', 'original_path')) -eq $OriginalPath) { $matches += $record }
    }
    Assert-True ($matches.Count -ge 1) "No history record for $OriginalPath"
    return $matches[-1]
}

function Assert-Deleted([string]$Root, [string]$OriginalPath) {
    Assert-True (-not (Test-Path -LiteralPath $OriginalPath)) "Original path still exists: $OriginalPath"
    $record = Get-Record $Root $OriginalPath
    $trashPath = Get-Field $record @('trashPath', 'trash_path', 'restorePath', 'restore_path')
    Assert-True (-not [string]::IsNullOrWhiteSpace($trashPath)) 'Missing recoverable trash path'
    Assert-True (Test-Path -LiteralPath $trashPath) "Deleted content is not recoverable: $trashPath"
    return $record
}

function Assert-Plan([string]$Root, [string]$Command, [string]$Expected) {
    $plan = Get-SafeDeleteCommandPlan -Command $Command -WorkingDirectory $Root -ProjectRoot $Root
    $script:evidence.Add([pscustomobject]@{ command = $Command; plan = $plan })
    Assert-True ($plan.action -eq $Expected) "Expected $Expected for '$Command', got '$($plan.action)': $($plan.reason)"
    return $plan
}

function Assert-OriginalBlocked($Result) {
    Assert-True ($Result.exitCode -eq 0) "Hook failed to produce a decision (exit $($Result.exitCode)); see process evidence"
    $decision = $Result.stdout | ConvertFrom-Json
    Assert-True ($decision.hookSpecificOutput.hookEventName -eq 'PreToolUse') 'Hook decision used the wrong event'
    if ($decision.hookSpecificOutput.permissionDecision -eq 'deny') {
        Assert-True ($decision.hookSpecificOutput.permissionDecisionReason -match 'Codex SafeDelete') 'Hook deny warning is missing'
    }
    else {
        Assert-True ($decision.hookSpecificOutput.permissionDecision -eq 'allow') 'Unexpected hook decision'
        Assert-True ($decision.hookSpecificOutput.PSObject.Properties['updatedInput'] -and $Result.replacementExecution) 'Hook allowed permanent deletion without a replacement command'
        Assert-True ($decision.systemMessage -match 'Codex SafeDelete') 'Hook replacement warning is missing'
    }
}

function Assert-DeleteRefused($Result) {
    Assert-OriginalBlocked $Result
    if ($Result.replacementExecution) {
        Assert-True ($Result.replacementExecution.exitCode -ne 0) 'Protected deletion unexpectedly succeeded'
    }
}

function Invoke-Case([string]$Name, [scriptblock]$Test, [string]$SkipReason = '') {
    $script:evidence.Clear()
    $started = [datetime]::UtcNow
    $status = 'PASS'
    $message = ''
    if ($SkipReason) { $status = 'NOT RUN'; $message = $SkipReason }
    else {
        try { & $Test }
        catch { $status = 'FAIL'; $message = $_.Exception.Message }
    }
    $record = [pscustomobject]@{
        name = $Name
        status = $status
        message = $message
        milliseconds = [math]::Round(([datetime]::UtcNow - $started).TotalMilliseconds)
        evidence = @($script:evidence.ToArray())
    }
    $script:results.Add($record)
    [IO.File]::AppendAllText($resultPath, ($record | ConvertTo-Json -Depth 16 -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('{0}: {1}{2}' -f $status, $Name, $(if ($message) { ' - ' + $message } else { '' }))
}

function Assert-PipeGuard {
    param([string]$Name, [byte[]]$OriginalBytes, [byte[]]$InstalledBytes, [byte[]]$CurrentBytes, [bool]$Expected, [switch]$CorruptBackup)
    $root = New-Fixture ('pipe-guard-' + $Name)
    $installDir = Join-Path $root 'installed'
    $backup = Join-Path $installDir 'backup\config.toml'
    $config = Join-Path $root 'codex-home\config.toml'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $config))
    [IO.File]::WriteAllBytes($backup, $OriginalBytes)
    [IO.File]::WriteAllBytes($config, $InstalledBytes)
    $snapshot = [pscustomobject]@{ name='config.toml'; path=$config; existed=$true; original_hash=(Get-SafeDeleteFileHash $backup); installed_hash=(Get-SafeDeleteFileHash $config) }
    [IO.File]::WriteAllBytes($config, $CurrentBytes)
    if ($CorruptBackup) { [IO.File]::AppendAllText($backup, '# damaged backup') }
    $currentHash = Get-SafeDeleteFileHash $config
    $backupHash = Get-SafeDeleteFileHash $backup
    $allowed = $false
    $threw = $false
    try { $allowed = Test-SafeDeleteDesktopPipeChange -Snapshot $snapshot -InstallDir $installDir }
    catch { $threw = $true }
    $unchanged = (Get-SafeDeleteFileHash $config) -eq $currentHash
    $backupUnchanged = (Get-SafeDeleteFileHash $backup) -eq $backupHash
    $script:evidence.Add([pscustomobject]@{ check=$Name; expected=$Expected; allowed=$allowed; threw=$threw; configurationUnchanged=$unchanged; backupUnchanged=$backupUnchanged })
    Assert-True ($allowed -eq $Expected) ("Pipe guard returned an unexpected decision: $Name")
    Assert-True ($unchanged -and $backupUnchanged) ("Pipe guard modified configuration or backup: $Name")
    if ($Expected) { Assert-True (-not $threw) ("Pipe guard threw for a valid rotation: $Name") }
    if ($CorruptBackup) { Assert-True $threw 'Pipe guard did not report the damaged backup checksum' }
}

$sourceHashes = @(Get-ProgramHashes)

Invoke-Case 'file delete, history, list, and undo' {
    $root = New-Fixture 'file'
    $file = Join-Path $root 'test.txt'
    [IO.File]::WriteAllText($file, 'recover this exact content')
    $deleted = Invoke-Cli -Action delete -Root $root -Paths @($file) -Command 'Remove-Item test.txt'
    Assert-True ($deleted.exitCode -eq 0) "delete failed (exit $($deleted.exitCode)); see process evidence"
    $record = Assert-Deleted $root $file
    Assert-True ((Get-Field $record @('name')) -eq 'test.txt') 'History name is missing or incorrect'
    Assert-True (-not [string]::IsNullOrWhiteSpace((Get-Field $record @('deletedAt', 'deleted_at', 'timestamp')))) 'History deletion time is missing'
    Assert-True ((Get-Field $record @('command', 'triggerCommand')) -eq 'Remove-Item test.txt') 'History trigger command is missing or incorrect'
    $listed = Invoke-Cli -Action list -Root $root
    Assert-True ($listed.exitCode -eq 0 -and $listed.stdout -match 'test.txt') 'list did not show deleted file'
    $undone = Invoke-Cli -Action undo -Root $root
    Assert-True ($undone.exitCode -eq 0) "undo failed (exit $($undone.exitCode)); see process evidence"
    Assert-True (Test-Path -LiteralPath $file -PathType Leaf) 'undo did not restore test.txt'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'recover this exact content') 'Restored file content changed'
}

Invoke-Case 'recursive folder hook delete and restore by id' {
    $root = New-Fixture 'folder'
    $folder = Join-Path $root 'test-folder'
    [void][IO.Directory]::CreateDirectory((Join-Path $folder 'nested'))
    [IO.File]::WriteAllText((Join-Path $folder 'one.txt'), 'one')
    [IO.File]::WriteAllText((Join-Path $folder 'nested\two.txt'), 'two')
    $hook = Invoke-ToolHook $root 'Remove-Item -Recurse -Force test-folder'
    Assert-OriginalBlocked $hook
    $record = Assert-Deleted $root $folder
    $id = Get-Field $record @('id')
    Assert-True (-not [string]::IsNullOrWhiteSpace($id)) 'History id is missing'
    $restored = Invoke-Cli -Action restore -Root $root -Id $id
    Assert-True ($restored.exitCode -eq 0) "restore failed (exit $($restored.exitCode)); see process evidence"
    Assert-True ([IO.File]::ReadAllText((Join-Path $folder 'one.txt')) -eq 'one') 'Folder first file was not restored'
    Assert-True ([IO.File]::ReadAllText((Join-Path $folder 'nested\two.txt')) -eq 'two') 'Folder nested file was not restored'
}

Invoke-Case 'quoted Unicode path and exec_command compatibility' {
    $root = New-Fixture 'unicode'
    $name = "space $([char]0x6D4B)$([char]0x8BD5)'s file.txt"
    $file = Join-Path $root $name
    [IO.File]::WriteAllText($file, 'unicode path content')
    $command = "Remove-Item -LiteralPath '" + $name.Replace("'", "''") + "'"
    $payload = @{
        hook_event_name = 'PreToolUse'; cwd = $root; tool_name = 'exec_command'
        tool_input = @{ cmd = $command; workdir = $root }
    } | ConvertTo-Json -Depth 8 -Compress
    $rawHook = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cli, '-Action', 'hook') -InputText $payload -WorkingDirectory $root
    $hook = Complete-ToolHook $rawHook $root
    Assert-OriginalBlocked $hook
    [void](Assert-Deleted $root $file)
    $undo = Invoke-Cli -Action undo -Root $root
    Assert-True ($undo.exitCode -eq 0) 'Unicode path undo failed'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'unicode path content') 'Quoted Unicode file was not restored correctly'
}

Invoke-Case 'hook replacement resolves target in actual tool working directory' {
    $root = New-Fixture 'actual-working-directory'
    $child = Join-Path $root 'child'
    [void][IO.Directory]::CreateDirectory($child)
    $rootFile = Join-Path $root 'test.txt'
    $childFile = Join-Path $child 'test.txt'
    [IO.File]::WriteAllText($rootFile, 'root must stay')
    [IO.File]::WriteAllText($childFile, 'child must be recovered')
    $hook = Invoke-ToolHook -Root $root -Command 'Remove-Item test.txt' -WorkingDirectory $child
    Assert-OriginalBlocked $hook
    [void](Assert-Deleted $root $childFile)
    Assert-True ([IO.File]::ReadAllText($rootFile) -eq 'root must stay') 'Hook used session cwd instead of actual tool working directory'
    $undo = Invoke-Cli -Action undo -Root $root
    Assert-True ($undo.exitCode -eq 0) 'Actual working-directory deletion could not be undone'
    Assert-True ([IO.File]::ReadAllText($childFile) -eq 'child must be recovered') 'Child path content did not restore'
}

Invoke-Case 'apply_patch file deletion denied for string and object inputs' {
    $root = New-Fixture 'patch-delete'
    $file = Join-Path $root 'test.txt'
    [IO.File]::WriteAllText($file, 'patch must preserve')
    $patch = "*** Begin Patch`n*** Delete File: test.txt`n*** End Patch"
    Assert-DeleteRefused (Invoke-PatchHook $root $patch)
    Assert-DeleteRefused (Invoke-PatchHook $root @{ command = $patch })
    Assert-True ([IO.File]::ReadAllText($file) -eq 'patch must preserve') 'Patch hook removed the file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Denied patch deletion created history'
}

Invoke-Case 'ordinary apply_patch source update allowed' {
    $root = New-Fixture 'patch-update'
    $file = Join-Path $root 'test.txt'
    [IO.File]::WriteAllText($file, 'original')
    $patch = "*** Begin Patch`n*** Update File: test.txt`n@@`n-original`n+changed`n*** End Patch"
    foreach ($toolInput in @($patch, @{ command = $patch })) {
        $result = Invoke-PatchHook $root $toolInput
        Assert-True ($result.exitCode -eq 0) 'Ordinary patch hook failed'
        $decision = $result.stdout | ConvertFrom-Json
        Assert-True (-not $decision.PSObject.Properties['hookSpecificOutput']) 'Ordinary patch was denied or rewritten'
    }
    Assert-True ([IO.File]::ReadAllText($file) -eq 'original') 'Hook modified content before the allowed patch execution'
}

Invoke-Case 'missing Storage module returns a blocking hook decision' {
    $root = New-Fixture 'missing-storage'
    foreach ($relative in @('src\safedelete.ps1', 'src\Commands.ps1', 'src\Protection.ps1', 'src\InstallState.ps1', 'hooks\pre-tool-use.ps1')) {
        $target = Join-Path $root $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $relative), $target)
    }
    $payload = @{ hook_event_name='PreToolUse'; cwd=$root; tool_name='Bash'; tool_input=@{command='Remove-Item test.txt'} } | ConvertTo-Json -Depth 6 -Compress
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hooks\pre-tool-use.ps1')) -InputText $payload -WorkingDirectory $root
    if ($result.exitCode -ne 2) { Assert-DeleteRefused (Complete-ToolHook $result $root) }
}

Invoke-Case 'missing CLI entry returns an explicit blocking hook decision' {
    $root = New-Fixture 'missing-cli'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'hooks'))
    [IO.File]::Copy((Join-Path $SourceRoot 'hooks\pre-tool-use.ps1'), (Join-Path $root 'hooks\pre-tool-use.ps1'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'src'))
    foreach ($name in @('Protection.ps1','InstallState.ps1')) { [IO.File]::Copy((Join-Path $SourceRoot ('src\'+$name)), (Join-Path $root ('src\'+$name))) }
    $payload = @{ hook_event_name='PreToolUse'; cwd=$root; tool_name='Bash'; tool_input=@{command='Remove-Item test.txt'} } | ConvertTo-Json -Depth 6 -Compress
    $file = Join-Path $root 'test.txt'
    [IO.File]::WriteAllText($file, 'preserve me')
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hooks\pre-tool-use.ps1')) -InputText $payload -WorkingDirectory $root
    Assert-True ($result.exitCode -eq 0) 'Explicit failure denial did not use a successful JSON transport exit'
    Assert-DeleteRefused (Complete-ToolHook $result $root)
    Assert-True ([IO.File]::ReadAllText($file) -ceq 'preserve me') 'Missing CLI changed the original contents'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Missing CLI created deletion history'
}

foreach ($sample in @(
    @{ name = 'rm'; command = 'rm test.txt'; directory = $false },
    @{ name = 'rm recursive'; command = 'rm -rf test-folder'; directory = $true },
    @{ name = 'del'; command = 'del test.txt'; directory = $false },
    @{ name = 'erase'; command = 'erase test.txt'; directory = $false },
    @{ name = 'rmdir'; command = 'rmdir /s /q test-folder'; directory = $true },
    @{ name = 'rd'; command = 'rd /s /q test-folder'; directory = $true },
    @{ name = 'Remove-Item'; command = 'Remove-Item -LiteralPath test.txt'; directory = $false },
    @{ name = 'PowerShell wrapper'; command = 'powershell -NoProfile -Command "Remove-Item test.txt"'; directory = $false }
)) {
    $case = $sample
    Invoke-Case ('actual hook deletion handling: ' + $case.name) {
        $root = New-Fixture ('command-' + ($case.name -replace ' ', '-'))
        if ($case.directory) {
            $target = Join-Path $root 'test-folder'
            [void][IO.Directory]::CreateDirectory($target)
            [IO.File]::WriteAllText((Join-Path $target 'payload.txt'), 'preserve me')
        }
        else {
            $target = Join-Path $root 'test.txt'
            [IO.File]::WriteAllText($target, 'preserve me')
        }
        if ($case.name -notin @('Remove-Item','PowerShell wrapper')) {
            [void](Assert-Plan $root $case.command 'deny')
            Assert-DeleteRefused (Invoke-ToolHook $root $case.command)
            Assert-True (Test-Path -LiteralPath $target) 'Ambiguous alias changed the original target'
            $payloadFile = if ($case.directory) { Join-Path $target 'payload.txt' } else { $target }
            Assert-True ([IO.File]::ReadAllText($payloadFile) -ceq 'preserve me') 'Ambiguous alias changed the original contents'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Ambiguous alias created deletion history'
            return
        }
        [void](Assert-Plan $root $case.command 'delete')
        $hook = Invoke-ToolHook $root $case.command
        Assert-OriginalBlocked $hook
        $record = Assert-Deleted $root $target
        $trashPath = Get-Field $record @('trashPath', 'trash_path', 'restorePath', 'restore_path')
        if ($case.directory) { $trashPath = Join-Path $trashPath 'payload.txt' }
        Assert-True ([IO.File]::ReadAllText($trashPath) -eq 'preserve me') 'Hook changed or lost content'
        $undo = Invoke-Cli -Action undo -Root $root
        Assert-True ($undo.exitCode -eq 0 -and (Test-Path -LiteralPath $target)) 'Hook deletion could not be undone'
    }
}

Invoke-Case 'project root recursive deletion is denied' {
    $root = New-Fixture 'root-deny'
    [IO.File]::WriteAllText((Join-Path $root 'sentinel.txt'), 'keep')
    Assert-DeleteRefused (Invoke-ToolHook $root 'Remove-Item -Recurse -Force .')
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'sentinel.txt')) -eq 'keep') 'Protected project root was modified'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Denied root deletion created a trash entry'
}

foreach ($name in @('.git', '.env', '.ssh')) {
    $protectedName = $name
    Invoke-Case ('protected path denied: ' + $protectedName) {
        $root = New-Fixture ('protected-' + $protectedName.Substring(1))
        $target = Join-Path $root $protectedName
        if ($protectedName -eq '.env') { [IO.File]::WriteAllText($target, 'SECRET=local-test') }
        else { [void][IO.Directory]::CreateDirectory($target) }
        $command = 'Remove-Item -Recurse -Force ' + $protectedName
        Assert-DeleteRefused (Invoke-ToolHook $root $command)
        Assert-True (Test-Path -LiteralPath $target) "Protected path disappeared: $protectedName"
        $direct = Invoke-Cli -Action delete -Root $root -Paths @($target)
        Assert-True ($direct.exitCode -ne 0 -and (Test-Path -LiteralPath $target)) 'Direct CLI bypassed protected-path rule'
    }
}

Invoke-Case 'drive root, C:\Users, and home are denied by program rules' {
    $root = New-Fixture 'system-plan'
    foreach ($target in @('C:\', 'C:\Users\', $env:USERPROFILE)) {
        Assert-DeleteRefused (Invoke-ToolHook $root ("Remove-Item -Recurse -Force '" + $target.Replace("'", "''") + "'"))
    }
}

Invoke-Case 'git clean and git reset --hard denied' {
    $root = New-Fixture 'git-danger'
    [IO.File]::WriteAllText((Join-Path $root 'sentinel.txt'), 'keep')
    foreach ($command in @('git clean -fd', 'git clean -fdx', 'git reset --hard', 'git reset --hard HEAD', 'git -c color.ui=false clean -fd', 'git reset --ha HEAD', 'git -c "alias.wipe=!rm -rf src" wipe')) {
        [void](Assert-Plan $root $command 'deny')
        Assert-DeleteRefused (Invoke-ToolHook $root $command)
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'sentinel.txt')) -eq 'keep') 'Dangerous git hook modified local content'
}

Invoke-Case 'restore conflict preserves both copies' {
    $root = New-Fixture 'conflict'
    $file = Join-Path $root 'test.txt'
    [IO.File]::WriteAllText($file, 'old version')
    $delete = Invoke-Cli -Action delete -Root $root -Paths @($file)
    Assert-True ($delete.exitCode -eq 0) 'Initial conflict-fixture deletion failed'
    $record = Assert-Deleted $root $file
    $trashPath = Get-Field $record @('trashPath', 'trash_path', 'restorePath', 'restore_path')
    [IO.File]::WriteAllText($file, 'new version')
    $restore = Invoke-Cli -Action restore -Root $root -Id (Get-Field $record @('id'))
    Assert-True ($restore.exitCode -ne 0) 'Conflicting restore unexpectedly succeeded'
    Assert-True ([IO.File]::ReadAllText($file) -eq 'new version') 'Restore overwrote an existing file'
    Assert-True ([IO.File]::ReadAllText($trashPath) -eq 'old version') 'Restore conflict destroyed the recoverable copy'
}

Invoke-Case 'recursive deletion over 1000 files denied' {
    $root = New-Fixture 'large-deny'
    $folder = Join-Path $root 'many'
    [void][IO.Directory]::CreateDirectory($folder)
    for ($index = 1; $index -le 1001; $index++) { [IO.File]::WriteAllText((Join-Path $folder ("$index.txt")), 'x') }
    Assert-DeleteRefused (Invoke-ToolHook $root 'Remove-Item -Recurse -Force many')
    Assert-True ([IO.Directory]::GetFiles($folder).Count -eq 1001) 'Large deletion changed fixture file count'
}

Invoke-Case 'compound, variable, and script deletes denied' {
    $root = New-Fixture 'ambiguous'
    [IO.File]::WriteAllText((Join-Path $root 'test.txt'), 'keep')
    [IO.File]::WriteAllText((Join-Path $root 'delete.ps1'), 'Remove-Item test.txt')
    foreach ($command in @(
        'Remove-Item test.txt; git status',
        '$p="test.txt"; Remove-Item $p',
        'powershell -File delete.ps1',
        '[IO.File]::"Delete"("test.txt")'
    )) {
        [void](Assert-Plan $root $command 'deny')
        Assert-DeleteRefused (Invoke-ToolHook $root $command)
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'test.txt')) -eq 'keep') 'Ambiguous deletion was executed'
}

Invoke-Case 'git status, npm test, and source edits allowed' {
    $root = New-Fixture 'ordinary'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'src'))
    foreach ($command in @('git status', 'npm test', "Set-Content -LiteralPath src\example.js -Value 'const value = 1;'", 'Set-Content -LiteralPath src\example.js -Value ''[IO.File]::Delete("test.txt")''')) {
        [void](Assert-Plan $root $command 'allow')
        $hook = Invoke-ToolHook $root $command
        Assert-True ($hook.exitCode -eq 0) "Ordinary command blocked: $command"
        $ordinaryDecision = $hook.stdout | ConvertFrom-Json
        Assert-True (-not $ordinaryDecision.PSObject.Properties['hookSpecificOutput']) "Ordinary command denied or rewritten: $command"
    }
    $quotedRoot = $root.Replace("'", "''")
    $scriptText = "Set-Location -LiteralPath '$quotedRoot'; git init --quiet; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }; git status --porcelain; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }; Set-Content -LiteralPath src\example.js -Value 'const value = 1;'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    $ordinary = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WorkingDirectory $root
    Assert-True ($ordinary.exitCode -eq 0) "git status or source edit failed (exit $($ordinary.exitCode)); see process evidence"
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'src\example.js')).Contains('const value = 1;')) 'Source editing did not work'
}

$npmSkipReason = ''
if (-not $NpmCliPath -and -not (Get-Command npm -ErrorAction SilentlyContinue)) { $npmSkipReason = 'npm is unavailable. Install npm or pass -NpmCliPath to a local npm-cli.js.' }
Invoke-Case -Name 'actual npm test executes local test script' -SkipReason $npmSkipReason -Test {
    $root = New-Fixture 'actual-npm'
    $quotedRoot = $root.Replace("'", "''")
    $quotedCache = (Join-Path $root 'npm-cache').Replace("'", "''")
    [IO.File]::WriteAllText((Join-Path $root 'package.json'), '{"name":"safedelete-local-test","version":"1.0.0","scripts":{"test":"node -e \"require(''fs'').writeFileSync(''npm-test-ran.txt'',''ran'')\""}}')
    $npmInvocation = 'npm test'
    $npmCheck = '$null = Get-Command npm -ErrorAction Stop; '
    if ($NpmCliPath) {
        Assert-True (Test-Path -LiteralPath $NpmCliPath -PathType Leaf) 'Specified npm CLI does not exist'
        $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
        $npmInvocation = "& '" + $nodePath.Replace("'", "''") + "' '" + ([IO.Path]::GetFullPath($NpmCliPath)).Replace("'", "''") + "' test"
        $npmCheck = ''
    }
    $npmScript = "`$ErrorActionPreference = 'Stop'; Set-Location -LiteralPath '$quotedRoot'; `$env:npm_config_cache='$quotedCache'; `$env:npm_config_offline='true'; `$env:npm_config_audit='false'; `$env:npm_config_fund='false'; `$env:npm_config_update_notifier='false'; " + $npmCheck + $npmInvocation + '; if ($null -eq $LASTEXITCODE) { throw "npm did not return an exit code" }; exit $LASTEXITCODE'
    $npmEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($npmScript))
    $npm = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $npmEncoded) -WorkingDirectory $root
    Assert-True ($npm.exitCode -eq 0) "npm test failed (exit $($npm.exitCode)); see process evidence"
    Assert-True ($npm.stdout -match '> node -e ') 'npm did not print the executed test command'
    $marker = Join-Path $root 'npm-test-ran.txt'
    Assert-True ((Test-Path -LiteralPath $marker -PathType Leaf) -and [IO.File]::ReadAllText($marker) -eq 'ran') 'npm test did not actually execute the Node test script'
}

Invoke-Case 'Desktop pipe rotation guard preserves UTF-8 BOM and line endings' {
    $oldPipe = '\\.\pipe\codex-computer-use-11111111-1111-4111-8111-111111111111'
    $newPipe = '\\.\pipe\codex-computer-use-22222222-2222-4222-8222-222222222222'
    $original = "# local Desktop fixture`nmodel = `"gpt-6.1-sol`"`n[mcp_servers.desktop_fixture.env]`nSKY_CUA_NATIVE_PIPE_DIRECTORY = '" + $oldPipe + "' # generated`n"
    $installed = $original + "`n[features]`nhooks = true`n"
    foreach ($mode in @('lf', 'crlf', 'bom-crlf')) {
        $before = $original
        $expected = $installed
        if ($mode -ne 'lf') { $before = $before.Replace("`n", "`r`n"); $expected = $expected.Replace("`n", "`r`n") }
        $current = $expected.Replace($oldPipe, $newPipe)
        $encoding = New-Object Text.UTF8Encoding($false)
        $prefix = [byte[]]@()
        if ($mode -eq 'bom-crlf') { $prefix = [byte[]]@(239,187,191) }
        Assert-PipeGuard -Name $mode -OriginalBytes ([byte[]]($prefix + $encoding.GetBytes($before))) -InstalledBytes ([byte[]]($prefix + $encoding.GetBytes($expected))) -CurrentBytes ([byte[]]($prefix + $encoding.GetBytes($current))) -Expected $true
    }
    $script:evidence.Add([pscustomobject]@{ check_count=3; configurations_modified_by_guard=0 })
}

Invoke-Case 'Desktop pipe rotation guard refuses unrelated edits and ambiguous configuration' {
    $oldPipe = '\\.\pipe\codex-computer-use-11111111-1111-4111-8111-111111111111'
    $newPipe = '\\.\pipe\codex-computer-use-22222222-2222-4222-8222-222222222222'
    $original = "# local Desktop fixture`nmodel = `"gpt-6.1-sol`"`n[mcp_servers.desktop_fixture.env]`nSKY_CUA_NATIVE_PIPE_DIRECTORY = '" + $oldPipe + "' # generated`n"
    $installed = $original + "`n[features]`nhooks = true`n"
    $rotated = $installed.Replace($oldPipe, $newPipe)
    $encoding = New-Object Text.UTF8Encoding($false)
    $cases = @(
        [pscustomobject]@{ name='other-setting'; current=$rotated.Replace('gpt-6.1-sol','user-selected-model'); ambiguous='' },
        [pscustomobject]@{ name='same-line-comment'; current=$rotated.Replace('# generated','# user change'); ambiguous='' },
        [pscustomobject]@{ name='same-line-spacing'; current=$rotated.Replace('DIRECTORY =','DIRECTORY  ='); ambiguous='' },
        [pscustomobject]@{ name='line-ending-change'; current=$rotated.Replace("`n","`r`n"); ambiguous='' },
        [pscustomobject]@{ name='not-native-pipe'; current=$installed.Replace($oldPipe,'C:\local-fixture'); ambiguous='' },
        [pscustomobject]@{ name='wrong-pipe-prefix'; current=$installed.Replace($oldPipe,'\\.\pipe\other-tool-22222222-2222-4222-8222-222222222222'); ambiguous='' },
        [pscustomobject]@{ name='invalid-guid'; current=$installed.Replace($oldPipe,'\\.\pipe\codex-computer-use-invalid'); ambiguous='' },
        [pscustomobject]@{ name='duplicate-key'; current=''; ambiguous=$original + "SKY_CUA_NATIVE_PIPE_DIRECTORY = '" + $oldPipe + "'`n" },
        [pscustomobject]@{ name='key-in-comment'; current=''; ambiguous=$original + "# SKY_CUA_NATIVE_PIPE_DIRECTORY example`n" },
        [pscustomobject]@{ name='wrong-table'; current=''; ambiguous=$original.Replace('[mcp_servers.desktop_fixture.env]','[unrelated.env]') },
        [pscustomobject]@{ name='quoted-table'; current=''; ambiguous=$original.Replace('[mcp_servers.desktop_fixture.env]','[mcp_servers."desktop_fixture".env]') },
        [pscustomobject]@{ name='quoted-key'; current=''; ambiguous=$original.Replace('SKY_CUA_NATIVE_PIPE_DIRECTORY =','"SKY_CUA_NATIVE_PIPE_DIRECTORY" =') },
        [pscustomobject]@{ name='multiline-toml'; current=''; ambiguous=$original + "notes = " + ('"' * 3) + "`nfixture`n" + ('"' * 3) + "`n" }
    )
    foreach ($case in $cases) {
        $before = $original
        $expected = $installed
        $current = $case.current
        if ($case.ambiguous) { $before = $case.ambiguous; $expected = $before + "`n[features]`nhooks = true`n"; $current = $expected.Replace($oldPipe,$newPipe) }
        Assert-PipeGuard -Name $case.name -OriginalBytes ($encoding.GetBytes($before)) -InstalledBytes ($encoding.GetBytes($expected)) -CurrentBytes ($encoding.GetBytes($current)) -Expected $false
    }
    Assert-PipeGuard -Name 'added-bom' -OriginalBytes ($encoding.GetBytes($original)) -InstalledBytes ($encoding.GetBytes($installed)) -CurrentBytes ([byte[]]([byte[]]@(239,187,191) + $encoding.GetBytes($rotated))) -Expected $false
    Assert-PipeGuard -Name 'invalid-utf8' -OriginalBytes ($encoding.GetBytes($original)) -InstalledBytes ($encoding.GetBytes($installed)) -CurrentBytes ([byte[]]($encoding.GetBytes($rotated) + [byte[]]@(255))) -Expected $false
    Assert-PipeGuard -Name 'damaged-backup' -OriginalBytes ($encoding.GetBytes($original)) -InstalledBytes ($encoding.GetBytes($installed)) -CurrentBytes ($encoding.GetBytes($rotated)) -Expected $false -CorruptBackup
    $script:evidence.Add([pscustomobject]@{ check_count=($cases.Count + 3); configurations_modified_by_guard=0 })
}

if (-not $SkipInstall) {
    Invoke-Case 'installation locks serialize shared directories before writes and release for retry' {
        $root = New-Fixture 'installation-mutex'
        $codexHome = Join-Path $root 'codex-home'; $otherHome = Join-Path $root 'other-home'
        $installDir = Join-Path $root 'installed'; $otherInstall = Join-Path $root 'other-installed'
        $preserved = @()
        foreach ($homePath in @($codexHome, $otherHome)) {
            [void][IO.Directory]::CreateDirectory($homePath)
            foreach ($name in @('config.toml', 'hooks.json')) {
                $path = Join-Path $homePath $name
                $content = if ($name -eq 'config.toml') { "# original mutex fixture`r`n" } else { '{"hooks":{}}' }
                [IO.File]::WriteAllText($path, $content)
                $preserved += [pscustomobject]@{ path=$path; hash=(Get-SafeDeleteFileHash $path) }
            }
        }
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User'); $processPathBefore = $env:Path
        $readyPath = Join-Path $root 'mutex-ready.txt'
        $mutexQuote = { param([string]$value) "'" + $value.Replace("'", "''") + "'" }
        $holdScript = '. ' + (& $mutexQuote (Join-Path $SourceRoot 'src\InstallState.ps1')) + "`r`n" +
            '$held = @(Enter-SafeDeleteInstallationLocks -InstallDir ' + (& $mutexQuote $installDir) + ' -CodexHome ' + (& $mutexQuote $codexHome) + ')' + "`r`n" +
            'try { [IO.File]::WriteAllText(' + (& $mutexQuote $readyPath) + ', ''ready''); [Console]::In.ReadLine() | Out-Null } finally { Exit-SafeDeleteInstallationLocks $held }'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holdScript))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $ShellPath
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
        $start.WorkingDirectory = $root
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false); $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $holder = New-Object Diagnostics.Process
        $holder.StartInfo = $start
        $started = $false; $stdoutTask = $null; $stderrTask = $null
        try {
            $started = $holder.Start()
            $stdoutTask = $holder.StandardOutput.ReadToEndAsync(); $stderrTask = $holder.StandardError.ReadToEndAsync()
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath $readyPath) -and -not $holder.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Assert-True ((Test-Path -LiteralPath $readyPath) -and -not $holder.HasExited) 'Isolated process did not acquire the installation mutexes; see holder evidence'
            foreach ($pair in @(
                [pscustomobject]@{ install=$installDir; home=$otherHome },
                [pscustomobject]@{ install=$otherInstall; home=$codexHome })) {
                $blocked = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$pair.home,'-InstallDir',$pair.install,'-NoPathUpdate') -WorkingDirectory $root
                Assert-True ($blocked.exitCode -ne 0 -and (Get-PlainProcessError $blocked.stderr) -match 'Another SafeDelete installation or uninstall' -and (Get-PlainProcessError $blocked.stderr) -match 'No changes were made') 'Concurrent installation did not clearly refuse the shared resource'
                Assert-True (-not (Test-Path -LiteralPath $installDir) -and -not (Test-Path -LiteralPath $otherInstall)) 'Busy mutex refusal wrote installation files'
                foreach ($entry in $preserved) { Assert-True ((Get-SafeDeleteFileHash $entry.path) -ceq $entry.hash) 'Busy mutex refusal modified original configuration' }
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Busy mutex refusal changed project history'
                Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Busy mutex refusal changed PATH'
            }
            $holder.StandardInput.WriteLine('release'); $holder.StandardInput.Flush(); $holder.StandardInput.Close()
            Assert-True ($holder.WaitForExit(15000) -and $holder.ExitCode -eq 0) 'Lock-holder did not release its mutexes cleanly'
            $installed = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($installed.exitCode -eq 0) 'Installation could not retry after mutex release'
            $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $installDir)) 'Mutex-protected installation could not uninstall'
            foreach ($entry in $preserved) { Assert-True ((Get-SafeDeleteFileHash $entry.path) -ceq $entry.hash) 'Install/uninstall after release changed the original configuration' }
            Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Mutex retry test changed PATH'
            $script:evidence.Add([pscustomobject]@{ sharedInstallDirRefused=$true; sharedCodexHomeRefused=$true; busyRefusalBeforeWrites=$true; releaseThenInstallAndUninstallSucceeded=$true; originalConfigurationsAndPathPreserved=$true })
        } finally {
            if ($started -and -not $holder.HasExited) {
                $holder.StandardInput.Close()
                if (-not $holder.WaitForExit(5000)) { $holder.Kill(); $holder.WaitForExit() }
            }
            if ($null -ne $stdoutTask) { [IO.File]::WriteAllText((Join-Path $root 'mutex-holder-stdout.txt'), $stdoutTask.Result, (New-Object Text.UTF8Encoding($false))) }
            if ($null -ne $stderrTask) { [IO.File]::WriteAllText((Join-Path $root 'mutex-holder-stderr.txt'), $stderrTask.Result, (New-Object Text.UTF8Encoding($false))) }
            $holder.Dispose()
        }
    }

    Invoke-Case 'config directory refuses installation before any changes' {
        $root = New-Fixture 'install-config-directory'
        $codexHome = Join-Path $root 'codex-home'; $installDir = Join-Path $root 'installed'
        $configPath = Join-Path $codexHome 'config.toml'; $hooksPath = Join-Path $codexHome 'hooks.json'
        [void][IO.Directory]::CreateDirectory($configPath)
        $sentinel = Join-Path $configPath 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'existing configuration directory content')
        [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}')
        $sentinelHash = Get-SafeDeleteFileHash $sentinel; $hooksHash = Get-SafeDeleteFileHash $hooksPath
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User'); $processPathBefore = $env:Path
        $blocked = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($blocked.exitCode -ne 0 -and (Get-PlainProcessError $blocked.stderr) -match 'config.toml must be a regular file') 'Installer did not clearly reject a config directory'
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Config directory refusal left installation or backup artifacts'
        Assert-True ((Get-SafeDeleteFileHash $sentinel) -ceq $sentinelHash -and (Get-SafeDeleteFileHash $hooksPath) -ceq $hooksHash) 'Config directory refusal changed existing configuration contents'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Config directory refusal created recovery history'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Config directory refusal changed PATH'
        $script:evidence.Add([pscustomobject]@{ configDirectoryRefused=$true; installDirNotCreated=$true; existingContentsUnchanged=$true; historyAndPathUnchanged=$true })
    }

    Invoke-Case 'unreadable config refuses installation before backup creation' {
        $root = New-Fixture 'install-unreadable-config'
        $codexHome = Join-Path $root 'codex-home'; $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'; $hooksPath = Join-Path $codexHome 'hooks.json'
        [IO.File]::WriteAllText($configPath, "# preserved config`r`n"); [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}')
        $configHash = Get-SafeDeleteFileHash $configPath; $hooksHash = Get-SafeDeleteFileHash $hooksPath
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User'); $processPathBefore = $env:Path
        $handle = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $blocked = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($blocked.exitCode -ne 0) 'Installer accepted unreadable original configuration'
            Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Unreadable config left installation or backup artifacts'
        } finally { $handle.Dispose() }
        Assert-True ((Get-SafeDeleteFileHash $configPath) -ceq $configHash -and (Get-SafeDeleteFileHash $hooksPath) -ceq $hooksHash) 'Unreadable config refusal changed original bytes'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Unreadable config refusal created recovery history'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Unreadable config refusal changed PATH'
        $script:evidence.Add([pscustomobject]@{ unreadableConfigRefused=$true; installDirNotCreated=$true; configurationHooksHistoryAndPathUnchanged=$true })
    }

    Invoke-Case 'backup copy failure cleans only preparation artifacts and permits retry' {
        $root = New-Fixture 'install-backup-copy-failure'
        $sourceCopy = New-InstallSourceFixture $root
        $installScript = Join-Path $sourceCopy 'install.ps1'
        $sourceText = [IO.File]::ReadAllText($installScript)
        $marker = '$ErrorActionPreference = ''Stop'''
        Assert-True ($sourceText.Contains($marker)) 'Copy fault fixture could not locate script-scope injection point'
        $mock = @('function Copy-Item {', '    param([string]$LiteralPath, [string]$Destination)', '    [IO.File]::WriteAllText($Destination, ''partial backup fixture'')', '    throw ''Injected backup copy failure.''', '}') -join "`r`n"
        [IO.File]::WriteAllText($installScript, $sourceText.Replace($marker, $marker + "`r`n" + $mock), (New-Object Text.UTF8Encoding($false)))
        $codexHome = Join-Path $root 'codex-home'; $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'; $hooksPath = Join-Path $codexHome 'hooks.json'
        [IO.File]::WriteAllText($configPath, "# preserved config`r`n"); [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}')
        $configHash = Get-SafeDeleteFileHash $configPath; $hooksHash = Get-SafeDeleteFileHash $hooksPath
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User'); $processPathBefore = $env:Path
        $blocked = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$installScript,'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($blocked.exitCode -ne 0 -and (Get-PlainProcessError $blocked.stderr) -match 'Injected backup copy failure') 'The scoped copy fault did not fail backup preparation'
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Failed backup preparation left a dirty installation that blocks retry'
        Assert-True ((Get-SafeDeleteFileHash $configPath) -ceq $configHash -and (Get-SafeDeleteFileHash $hooksPath) -ceq $hooksHash) 'Backup preparation failure restored or changed original configuration'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\history.json'))) 'Backup preparation failure created recovery history'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Backup preparation failure changed PATH'
        $script:evidence.Add([pscustomobject]@{ backupCopyFault=$true; partialBackupRemoved=$true; installDirRemoved=$true; retryNotBlockedByArtifacts=$true; configurationHooksHistoryAndPathUnchanged=$true })
    }

    foreach ($existingConfiguration in @($true,$false)) {
        $label = if ($existingConfiguration) { 'edited' } else { 'new' }
        Invoke-Case ("rolled-back cleanup preserves $label configuration hooks and current PATH") {
            $fixture = New-RolledBackFixture ('rollback-' + $label) $existingConfiguration
            $configPath = Join-Path $fixture.codexHome 'config.toml'
            $hooksPath = Join-Path $fixture.codexHome 'hooks.json'
            [IO.File]::WriteAllText($configPath, "# user's configuration after rollback`r`n", (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($hooksPath, '{"hooks":{"PreToolUse":[]},"user_after_rollback":true}', (New-Object Text.UTF8Encoding($false)))
            $configHash = Get-SafeDeleteFileHash $configPath
            $hooksHash = Get-SafeDeleteFileHash $hooksPath
            $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
            $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture.installDir 'uninstall.ps1'),'-CodexHome',$fixture.codexHome,'-InstallDir',$fixture.installDir,'-NoPathUpdate') -WorkingDirectory $fixture.root
            Assert-True ($uninstalled.exitCode -eq 0) "Rollback cleanup failed (exit $($uninstalled.exitCode)); see process evidence"
            Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $configHash) 'Rollback cleanup replaced or removed later user configuration'
            Assert-True ((Get-SafeDeleteFileHash $hooksPath) -eq $hooksHash) 'Rollback cleanup replaced or removed later user hooks'
            Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Rollback cleanup changed the real User PATH'
            Assert-True (-not (Test-Path -LiteralPath $fixture.installDir)) 'Rollback cleanup left installed files behind'
            $script:evidence.Add([pscustomobject]@{ originalFilesExisted=$existingConfiguration; laterConfigurationPreserved=$true; laterHooksPreserved=$true; pathRestorationTrapped=$true; realUserPathUnchanged=$true; installationRemoved=$true })
        }
    }

    Invoke-Case 'failed rollback state writes leave uncertain installations protected' {
        foreach ($failurePhase in @('rolling-back','rolled-back')) {
            $root = New-Fixture ('rollback-write-failure-' + $failurePhase)
            $sourceCopy = New-InstallSourceFixture $root
            $codexHome = Join-Path $root 'codex-home'
            $installDir = Join-Path $root 'installed'
            [void][IO.Directory]::CreateDirectory($codexHome)
            $configPath = Join-Path $codexHome 'config.toml'
            $hooksPath = Join-Path $codexHome 'hooks.json'
            [IO.File]::WriteAllText($configPath, "# original configuration`r`n", (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}', (New-Object Text.UTF8Encoding($false)))
            $originalConfigHash = Get-SafeDeleteFileHash $configPath
            $originalHooksHash = Get-SafeDeleteFileHash $hooksPath
            [IO.File]::AppendAllText((Join-Path $sourceCopy 'hooks\Trust.ps1'), "`r`nfunction Get-SafeDeleteHookRegistration { throw 'Injected local hook registration failure.' }`r`n")
            $fault = @'

function Write-SafeDeleteJson {
    param([string]$Path, $Value)
    if ($Value.PSObject.Properties['phase'] -and $Value.phase -eq 'FAULT_PHASE') { throw 'Injected rollback state write failure.' }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    Write-SafeDeleteBytes $Path ($encoding.GetBytes(($Value | ConvertTo-Json -Depth 30)))
}
'@
            [IO.File]::AppendAllText((Join-Path $sourceCopy 'src\InstallState.ps1'), $fault.Replace('FAULT_PHASE',$failurePhase), (New-Object Text.UTF8Encoding($false)))
            $failedInstall = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $sourceCopy 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($failedInstall.exitCode -ne 0 -and $failedInstall.stderr -match 'Injected rollback state write failure') 'Installer did not encounter the injected rollback state write failure'
            $statePath = Join-Path $installDir 'install-state.json'
            $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            $expectedPhase = if ($failurePhase -eq 'rolling-back') { 'installing' } else { 'rolling-back' }
            Assert-True ($state.phase -eq $expectedPhase) 'Failed state write left a state that can be unsafely uninstalled'
            if ($failurePhase -eq 'rolled-back') {
                Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $originalConfigHash -and (Get-SafeDeleteFileHash $hooksPath) -eq $originalHooksHash) 'Rollback did not restore configuration before its final state write failed'
            }
            [IO.File]::AppendAllText($configPath, "`r`n# later user configuration`r`n")
            [IO.File]::AppendAllText($hooksPath, "`r`n ")
            $configHash = Get-SafeDeleteFileHash $configPath
            $hooksHash = Get-SafeDeleteFileHash $hooksPath
            $stateHash = Get-SafeDeleteFileHash $statePath
            $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
            $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($uninstalled.exitCode -ne 0) 'Uninstall accepted an uncertain rollback state'
            Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $configHash -and (Get-SafeDeleteFileHash $hooksPath) -eq $hooksHash) 'Uninstall changed configuration during uncertain rollback'
            Assert-True ((Get-SafeDeleteFileHash $statePath) -eq $stateHash) 'Uninstall changed uncertain installation state'
            Assert-True ((Get-SafeDeleteFileHash (Join-Path $installDir 'backup\config.toml')) -eq $originalConfigHash -and (Get-SafeDeleteFileHash (Join-Path $installDir 'backup\hooks.json')) -eq $originalHooksHash) 'Uninstall removed or changed rollback backups'
            Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Uncertain rollback uninstall changed the real User PATH'
            $script:evidence.Add([pscustomobject]@{ failedStateWrite=$failurePhase; persistedPhase=$state.phase; uninstallRefused=$true; laterConfigurationPreserved=$true; laterHooksPreserved=$true; backupsPreserved=$true; realUserPathUnchanged=$true })
        }
    }

    Invoke-Case 'hook verification timeout rolls back and permits cleanup before reinstall' {
        $root = New-Fixture 'installation-timeout-retry'
        $sourceCopy = New-InstallSourceFixture $root
        $hookPath = Join-Path $sourceCopy 'hooks\pre-tool-use.ps1'
        $hookSource = [IO.File]::ReadAllText($hookPath)
        $marker = 'param([switch]$Worker)'
        Assert-True ($hookSource.Contains($marker)) 'Hook parameter marker changed; update the timeout fixture deliberately'
        [IO.File]::WriteAllText($hookPath, $hookSource.Replace($marker, $marker + "`r`nStart-Sleep -Seconds 11"), (New-Object Text.UTF8Encoding($false)))
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        [IO.File]::WriteAllText($configPath, "# original configuration`r`n", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}', (New-Object Text.UTF8Encoding($false)))
        $originalConfigHash = Get-SafeDeleteFileHash $configPath
        $originalHooksHash = Get-SafeDeleteFileHash $hooksPath
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
        $failedInstall = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $sourceCopy 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($failedInstall.exitCode -ne 0 -and $failedInstall.stderr -match 'Hook runtime verification timed out') 'Installer did not report the real hook verification timeout'
        $state = [IO.File]::ReadAllText((Join-Path $installDir 'install-state.json')) | ConvertFrom-Json
        Assert-True ($state.phase -eq 'rolled-back') 'Timed out installation did not complete rollback'
        Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $originalConfigHash -and (Get-SafeDeleteFileHash $hooksPath) -eq $originalHooksHash) 'Timeout rollback did not restore original configuration and hooks'
        [IO.File]::AppendAllText($configPath, "# user's change after timeout`r`n")
        [IO.File]::AppendAllText($hooksPath, "`r`n")
        $laterConfigHash = Get-SafeDeleteFileHash $configPath
        $laterHooksHash = Get-SafeDeleteFileHash $hooksPath
        $uninstallArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate')
        $cleanup = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
        Assert-True ($cleanup.exitCode -eq 0 -and -not (Test-Path -LiteralPath $installDir)) 'Timed out installation could not be safely cleaned up'
        Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $laterConfigHash -and (Get-SafeDeleteFileHash $hooksPath) -eq $laterHooksHash) 'Timeout cleanup overwrote later configuration or hooks'
        $installed = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($installed.exitCode -eq 0) "Reinstall after timeout cleanup failed (exit $($installed.exitCode)); see process evidence"
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0) 'Reinstalled fixture could not be uninstalled'
        Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $laterConfigHash -and (Get-SafeDeleteFileHash $hooksPath) -eq $laterHooksHash) 'Reinstall and uninstall did not preserve the later user configuration'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Timeout retry test changed the real User PATH'
        $script:evidence.Add([pscustomobject]@{ realHookTimeout=$true; rollbackCompleted=$true; cleanupPreservedLaterConfiguration=$true; reinstallSucceeded=$true; reinstallUninstallPreservedBaseline=$true; realUserPathUnchanged=$true })
    }

    Invoke-Case 'isolated install, repeat install, and exact uninstall restoration' {
        $root = New-Fixture 'installation'
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        $originalConfig = "# pre-existing user config`r`nmodel = `"gpt-6.1-sol`"`r`n"
        $originalHooks = '{"hooks":{"PreToolUse":[{"matcher":"^Read$","hooks":[{"type":"command","command":"Write-Output pre-existing"}]}]}}'
        [IO.File]::WriteAllText($configPath, $originalConfig, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($hooksPath, $originalHooks, (New-Object Text.UTF8Encoding($false)))
        $originalBytes = [IO.File]::ReadAllBytes($configPath)
        $originalHookBytes = [IO.File]::ReadAllBytes($hooksPath)
        $installArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'install.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate')
        $installed = Invoke-Process -Program $ShellPath -Arguments $installArgs -WorkingDirectory $root
        Assert-True ($installed.exitCode -eq 0) "Installation failed (exit $($installed.exitCode)); see process evidence"
        Assert-True ($installed.stdout -match 'Codex SafeDelete installed') 'Installer did not confirm verified installation'
        Assert-True (Test-Path -LiteralPath $installDir -PathType Container) 'Install directory missing'
        Assert-True (Test-Path -LiteralPath (Join-Path $root '.codex-safedelete\trash') -PathType Container) 'Installer did not initialize local trash'
        $installedHooks = [IO.File]::ReadAllText($hooksPath) | ConvertFrom-Json
        $preserved = @($installedHooks.hooks.PreToolUse | Where-Object { $_.matcher -eq '^Read$' })
        Assert-True ($preserved.Count -eq 1 -and $preserved[0].hooks[0].command -eq 'Write-Output pre-existing') 'Installer lost an existing hook'
        $registered = @($installedHooks.hooks.PreToolUse | Where-Object { $_.matcher -eq '^(Bash|apply_patch)$' })
        Assert-True ($registered.Count -eq 1) 'Installed matcher does not protect Bash and apply_patch'
        $hookEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($registered[0].hooks[0].command))
        $hookPayload = @{ hook_event_name='PreToolUse'; cwd=$root; tool_name='Bash'; tool_input=@{command='Remove-Item -Recurse -Force .'} } | ConvertTo-Json -Depth 6 -Compress
        $runtimeHook = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $hookEncoded) -InputText $hookPayload -WorkingDirectory $root
        Assert-DeleteRefused (Complete-ToolHook $runtimeHook $root)
        $installedShim = Join-Path $installDir 'safedelete.cmd'
        Assert-True (Test-Path -LiteralPath $installedShim -PathType Leaf) 'Installed command shim missing'
        $file = Join-Path $root 'test.txt'
        [IO.File]::WriteAllText($file, 'installed command content')
        foreach ($action in @('delete test.txt', 'undo')) {
            $shimScript = "& '" + $installedShim.Replace("'", "''") + "' " + $action + '; exit $LASTEXITCODE'
            $shimEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shimScript))
            $shimResult = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $shimEncoded) -WorkingDirectory $root
            Assert-True ($shimResult.exitCode -eq 0) "Installed safedelete $action failed (exit $($shimResult.exitCode)); see process evidence"
            if ($action -eq 'delete test.txt') { [void](Assert-Deleted $root $file) }
        }
        Assert-True ([IO.File]::ReadAllText($file) -eq 'installed command content') 'Installed safedelete undo did not restore content'
        $repeat = Invoke-Process -Program $ShellPath -Arguments $installArgs -WorkingDirectory $root
        Assert-True ($repeat.exitCode -eq 0) "Repeated installation failed (exit $($repeat.exitCode)); see process evidence"
        Assert-True ($repeat.stdout -match 'existing files were not updated') 'Repeated installation did not explain that existing files were not updated'
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'uninstall.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0) "Uninstall failed (exit $($uninstalled.exitCode)); see process evidence"
        Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) 'Uninstall removed existing config'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($originalBytes)) 'Uninstall did not restore config byte for byte'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hooksPath)) -eq [Convert]::ToBase64String($originalHookBytes)) 'Uninstall did not restore hooks byte for byte'
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Uninstall left installed program files behind'
    }

    Invoke-Case 'repeat installation refuses an older runtime without changing the installation' {
        $root = New-Fixture 'repeat-install-version-mismatch'
        $sourceCopy = New-InstallSourceFixture $root
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        [IO.File]::WriteAllText($configPath, "# pre-existing user config`r`n", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($hooksPath, '{"hooks":{"PreToolUse":[]}}', (New-Object Text.UTF8Encoding($false)))
        $originalConfigHash = Get-SafeDeleteFileHash $configPath
        $originalHooksHash = Get-SafeDeleteFileHash $hooksPath
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
        $processPathBefore = $env:Path
        # A harmless comment represents an older runtime while keeping the real
        # installation and its original uninstaller fully operational.
        [IO.File]::AppendAllText((Join-Path $sourceCopy 'src\Storage.ps1'), "`r`n# Older runtime fixture.`r`n", (New-Object Text.UTF8Encoding($false)))
        $installed = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $sourceCopy 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($installed.exitCode -eq 0) 'Older runtime fixture installation failed; see process evidence'
        Assert-True ((Get-SafeDeleteFileHash (Join-Path $SourceRoot 'src\Storage.ps1')) -cne (Get-SafeDeleteFileHash (Join-Path $installDir 'src\Storage.ps1'))) 'Fixture did not create a source/runtime mismatch'
        $preservedPaths = @($configPath,$hooksPath,(Join-Path $installDir 'install-state.json'),(Join-Path $installDir 'protection-state.json'))
        foreach ($relative in @(Get-SafeDeleteInstallManifest)) { $preservedPaths += (Join-Path $installDir $relative) }
        foreach ($name in @('config.toml','hooks.json')) { $preservedPaths += (Join-Path $installDir ('backup\' + $name)) }
        $before = @($preservedPaths | ForEach-Object { [pscustomobject]@{ path=$_; hash=(Get-SafeDeleteFileHash $_) } })
        $repeat = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($repeat.exitCode -ne 0) 'Repeated installation reported success while keeping an older runtime'
        $repeatMessage = Get-PlainProcessError $repeat.stderr
        Assert-True ($repeatMessage -match 'Installed files differ' -and $repeatMessage -match 'does not upgrade' -and $repeatMessage -match 'Uninstall SafeDelete.cmd') 'Version mismatch did not explain the safe uninstall and reinstall procedure'
        Assert-True ($repeat.stdout -notmatch 'Already installed and verified') 'Blocked repeated installation reported verified success'
        foreach ($entry in $before) { Assert-True ((Get-SafeDeleteFileHash $entry.path) -ceq $entry.hash) ('Blocked repeated installation modified ' + $entry.path) }
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Blocked repeated installation changed User PATH'
        Assert-True ([string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Blocked repeated installation changed process PATH'
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $installDir 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $installDir)) 'Blocked repeated installation could not be cleaned up by its original uninstaller'
        Assert-True ((Get-SafeDeleteFileHash $configPath) -ceq $originalConfigHash -and (Get-SafeDeleteFileHash $hooksPath) -ceq $originalHooksHash) 'Original uninstaller did not restore the fixture configuration and hooks'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Mismatch fixture changed the real User PATH'
        $script:evidence.Add([pscustomobject]@{ runtimeMismatchRefused=$true; preservedFileCount=$before.Count; configurationHooksStateProgramsAndBackupsUnchanged=$true; userPathUnchanged=$true; processPathUnchanged=$true; originalUninstallSucceeded=$true })
    }

    Invoke-Case 'orphan SafeDelete registrations refuse fresh installation before any changes' {
        foreach ($count in @(1,2)) {
            $root = New-Fixture ('orphan-install-' + $count)
            $codexHome = Join-Path $root 'codex-home'
            $installDir = Join-Path $root 'installed'
            [void][IO.Directory]::CreateDirectory($codexHome)
            $configPath = Join-Path $codexHome 'config.toml'
            $hooksPath = Join-Path $codexHome 'hooks.json'
            [IO.File]::WriteAllText($configPath, "# existing user config`r`n", (New-Object Text.UTF8Encoding($false)))
            $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $hookScript = Join-Path $installDir 'hooks\pre-tool-use.ps1'
            $expectedCommand = "& '" + $shell.Replace("'", "''") + "' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '" + $hookScript.Replace("'", "''") + "'"
            $entries = @([pscustomobject]@{ matcher='^Read$'; hooks=@([pscustomobject]@{ type='command'; command='Write-Output pre-existing' }) })
            for ($i=0; $i -lt $count; $i++) {
                $entries += [pscustomobject]@{ matcher='^(Bash|apply_patch)$'; hooks=@([pscustomobject]@{ type='command'; command=$expectedCommand; timeout=30; statusMessage='Codex SafeDelete' }) }
            }
            Write-SafeDeleteJson $hooksPath ([pscustomobject]@{ hooks=[pscustomobject]@{ PreToolUse=$entries } })
            [IO.File]::WriteAllText((Join-Path $root 'history-fixture.txt'), 'existing recoverable deletion')
            $saved = Invoke-Cli -Action 'delete' -Root $root -Paths @('history-fixture.txt')
            Assert-True ($saved.exitCode -eq 0) 'Orphan fixture could not create existing recoverable history'
            $storePath = Join-Path $root '.codex-safedelete'
            $storeFiles = @(Get-ChildItem -LiteralPath $storePath -Recurse -Force | Where-Object { -not $_.PSIsContainer })
            Assert-True ($storeFiles.Count -gt 0) 'Orphan fixture has no existing store history'
            $preservedPaths = @($configPath,$hooksPath) + @($storeFiles | ForEach-Object { $_.FullName })
            $before = @($preservedPaths | ForEach-Object { [pscustomobject]@{ path=$_; hash=(Get-SafeDeleteFileHash $_) } })
            $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
            $processPathBefore = $env:Path
            $blocked = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate') -WorkingDirectory $root
            Assert-True ($blocked.exitCode -ne 0) ('Installation accepted ' + $count + ' orphan SafeDelete hooks')
            $message = Get-PlainProcessError $blocked.stderr
            Assert-True ($message -match 'already registered without matching installation state' -and $message -match 'No changes were made' -and $message -match 'resolve the orphan registration') 'Orphan registration refusal did not explain the safe recovery procedure'
            Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Orphan registration refusal created an installation or backup directory'
            foreach ($entry in $before) { Assert-True ((Get-SafeDeleteFileHash $entry.path) -ceq $entry.hash) ('Orphan registration refusal changed ' + $entry.path) }
            Assert-True (@(Get-ChildItem -LiteralPath $storePath -Recurse -Force | Where-Object { -not $_.PSIsContainer }).Count -eq $storeFiles.Count) 'Orphan registration refusal added store files or history'
            Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Orphan registration refusal changed User PATH'
            Assert-True ([string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Orphan registration refusal changed process PATH'
            $script:evidence.Add([pscustomobject]@{ orphanHookCount=$count; refusedBeforeInstallation=$true; installDirNotCreated=$true; configurationAndHooksUnchanged=$true; storeFileCount=$storeFiles.Count; storeHistoryAndPayloadUnchanged=$true; userPathUnchanged=$true; processPathUnchanged=$true })
        }
    }

    Invoke-Case 'uninstall refuses to overwrite configuration edited after installation' {
        $root = New-Fixture 'installation-conflict'
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        [IO.File]::WriteAllText($configPath, "# original`r`n", (New-Object Text.UTF8Encoding($false)))
        $installed = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'install.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($installed.exitCode -eq 0) "Conflict fixture installation failed (exit $($installed.exitCode)); see process evidence"
        $installedConfig = [IO.File]::ReadAllBytes($configPath)
        [IO.File]::AppendAllText($configPath, "`r`n# user's later change`r`n")
        $changedConfig = [IO.File]::ReadAllBytes($configPath)
        $uninstallArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'uninstall.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate')
        $blocked = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
        Assert-True ($blocked.exitCode -ne 0) 'Uninstall unexpectedly overwrote changed configuration'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($changedConfig)) 'Blocked uninstall modified changed configuration'
        Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'backup\config.toml')) 'Blocked uninstall removed the original backup'
        [IO.File]::WriteAllBytes($configPath, $installedConfig)
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0) 'Uninstall still failed after fixture conflict was resolved'
        Assert-True ([IO.File]::ReadAllText($configPath) -eq "# original`r`n") 'Resolved uninstall did not restore original config'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome 'hooks.json'))) 'Uninstall left a hook configuration that did not exist before installation'
    }
    Invoke-Case 'Desktop pipe rotation uninstalls while user configuration, hooks, and PATH conflicts remain protected' {
        $root = New-Fixture 'desktop-pipe-installation'
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        [void][IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        $statePath = Join-Path $installDir 'install-state.json'
        $encoding = New-Object Text.UTF8Encoding($false)
        $oldPipe = '\\.\pipe\codex-computer-use-11111111-1111-4111-8111-111111111111'
        $newPipe = '\\.\pipe\codex-computer-use-22222222-2222-4222-8222-222222222222'
        $originalConfig = "# local Desktop fixture`r`nmodel = `"gpt-6.1-sol`"`r`n[mcp_servers.desktop_fixture]`r`ncommand = `"cmd.exe`"`r`nargs = [`"/d`", `"/c`", `"exit 0`"]`r`n[mcp_servers.desktop_fixture.env]`r`nSKY_CUA_NATIVE_PIPE_DIRECTORY = '" + $oldPipe + "'`r`n"
        $originalHooks = '{"hooks":{"PreToolUse":[{"matcher":"^Read$","hooks":[{"type":"command","command":"Write-Output pre-existing"}]}]}}'
        [IO.File]::WriteAllText($configPath, $originalConfig, $encoding)
        [IO.File]::WriteAllText($hooksPath, $originalHooks, $encoding)
        $originalBytes = [IO.File]::ReadAllBytes($configPath)
        $originalHookBytes = [IO.File]::ReadAllBytes($hooksPath)
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
        $installArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'install.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate')
        $installed = Invoke-Process -Program $ShellPath -Arguments $installArgs -WorkingDirectory $root
        Assert-True ($installed.exitCode -eq 0) "Desktop pipe fixture installation failed (exit $($installed.exitCode)); see process evidence"
        $installedText = $encoding.GetString([IO.File]::ReadAllBytes($configPath))
        Assert-True ($installedText.Contains($oldPipe)) 'Installer unexpectedly changed the original Desktop pipe value'
        $rotatedText = $installedText.Replace($oldPipe, $newPipe)
        $rotatedBytes = $encoding.GetBytes($rotatedText)
        $installedHookBytes = [IO.File]::ReadAllBytes($hooksPath)
        $installedStateBytes = [IO.File]::ReadAllBytes($statePath)
        $uninstallArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'uninstall.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate')
        $assertRefused = {
            param([string]$Label)
            $configHash = Get-SafeDeleteFileHash $configPath
            $hooksHash = Get-SafeDeleteFileHash $hooksPath
            $stateHash = Get-SafeDeleteFileHash $statePath
            $backupHash = Get-SafeDeleteFileHash (Join-Path $installDir 'backup\config.toml')
            $blocked = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
            Assert-True ($blocked.exitCode -ne 0) ("Uninstall ignored $Label conflict")
            Assert-True ((Get-SafeDeleteFileHash $configPath) -eq $configHash) ("Uninstall overwrote configuration during $Label conflict")
            Assert-True ((Get-SafeDeleteFileHash $hooksPath) -eq $hooksHash) ("Uninstall overwrote hooks during $Label conflict")
            Assert-True ((Get-SafeDeleteFileHash $statePath) -eq $stateHash) ("Uninstall removed or modified state during $Label conflict")
            Assert-True ((Get-SafeDeleteFileHash (Join-Path $installDir 'backup\config.toml')) -eq $backupHash) ("Uninstall removed or modified backup during $Label conflict")
            Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'), $userPathBefore, [StringComparison]::Ordinal)) 'Uninstall conflict test changed the real User PATH'
            $script:evidence.Add([pscustomobject]@{ conflict=$Label; denied=$true; configurationUnchanged=$true; hooksUnchanged=$true; stateUnchanged=$true; backupUnchanged=$true; userPathUnchanged=$true })
        }
        [IO.File]::WriteAllBytes($configPath, $encoding.GetBytes($rotatedText + "`r`n# user's later change`r`n"))
        & $assertRefused 'configuration'
        [IO.File]::WriteAllBytes($configPath, $rotatedBytes)
        [IO.File]::WriteAllBytes($hooksPath, [byte[]]($installedHookBytes + $encoding.GetBytes("`r`n")))
        & $assertRefused 'hooks'
        [IO.File]::WriteAllBytes($hooksPath, $installedHookBytes)
        $state = $encoding.GetString($installedStateBytes) | ConvertFrom-Json
        $state.path_updated = $true
        $state.installed_user_path = 'SAFEDELETE_TEST_NONMATCH_' + [guid]::NewGuid().ToString('N')
        Write-SafeDeleteJson $statePath $state
        & $assertRefused 'User PATH'
        [IO.File]::WriteAllBytes($statePath, $installedStateBytes)
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments $uninstallArgs -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0) "Uninstall rejected only the Desktop pipe rotation (exit $($uninstalled.exitCode)); see process evidence"
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($originalBytes)) 'Pipe rotation uninstall did not restore original config bytes'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hooksPath)) -eq [Convert]::ToBase64String($originalHookBytes)) 'Pipe rotation uninstall did not restore original hooks bytes'
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Pipe rotation uninstall left installed program files behind'
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'), $userPathBefore, [StringComparison]::Ordinal)) 'Isolated pipe uninstall test changed the real User PATH'
        $script:evidence.Add([pscustomobject]@{ denied_conflicts=3; automatic_pipe_rotation_uninstall=$true; originalConfigurationRestoredByteForByte=$true; originalHooksRestoredByteForByte=$true; installationRemoved=$true; realUserPathUnchanged=$true })
    }
}

$finalSourceHashes = @(Get-ProgramHashes)
Invoke-Case 'tested program source hashes unchanged during execution' {
    $script:evidence.Add([pscustomobject]@{ sha256 = $finalSourceHashes })
    foreach ($source in $sourceHashes) {
        $final = @($finalSourceHashes | Where-Object { $_.path -eq $source.path })
        Assert-True ($final.Count -eq 1 -and $source.sha256 -eq $final[0].sha256) ("Source changed during execution: " + $source.path)
    }
}

$passed = @($script:results | Where-Object { $_.status -eq 'PASS' }).Count
$failed = @($script:results | Where-Object { $_.status -eq 'FAIL' }).Count
$notRun = @($script:results | Where-Object { $_.status -eq 'NOT RUN' }).Count
$summary = [pscustomobject]@{
    shell = $ShellPath
    powershell = $PSVersionTable.PSVersion.ToString()
    runId = $runId
    total = $script:results.Count
    passed = $passed
    failed = $failed
    notRun = $notRun
    npmCliPath = $NpmCliPath
    evidence = $resultPath
    fixtures = $runRoot
    sourceHashes = $finalSourceHashes
}
[IO.File]::WriteAllText((Join-Path $runRoot 'summary.json'), ($summary | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host ("TOTAL: {0}; PASS: {1}; FAIL: {2}; NOT RUN: {3}" -f $script:results.Count, $passed, $failed, $notRun)
Write-Host "Evidence: $resultPath"
if ($failed -gt 0) { exit 1 }
exit 0
