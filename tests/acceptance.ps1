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
    foreach ($relative in @('install.ps1', 'uninstall.ps1', 'src\Storage.ps1', 'src\Commands.ps1', 'src\safedelete.ps1', 'src\InstallState.ps1', 'hooks\pre-tool-use.ps1', 'hooks\Trust.ps1', 'tests\acceptance.ps1')) {
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
    $command = "rm '" + $name.Replace("'", "''") + "'"
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
    foreach ($relative in @('src\safedelete.ps1', 'src\Commands.ps1', 'hooks\pre-tool-use.ps1')) {
        $target = Join-Path $root $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $relative), $target)
    }
    $payload = @{ hook_event_name='PreToolUse'; cwd=$root; tool_name='Bash'; tool_input=@{command='Remove-Item test.txt'} } | ConvertTo-Json -Depth 6 -Compress
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hooks\pre-tool-use.ps1')) -InputText $payload -WorkingDirectory $root
    if ($result.exitCode -ne 2) { Assert-DeleteRefused (Complete-ToolHook $result $root) }
}

Invoke-Case 'missing CLI entry makes hook exit 2' {
    $root = New-Fixture 'missing-cli'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'hooks'))
    [IO.File]::Copy((Join-Path $SourceRoot 'hooks\pre-tool-use.ps1'), (Join-Path $root 'hooks\pre-tool-use.ps1'))
    $payload = @{ hook_event_name='PreToolUse'; cwd=$root; tool_name='Bash'; tool_input=@{command='Remove-Item test.txt'} } | ConvertTo-Json -Depth 6 -Compress
    $result = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hooks\pre-tool-use.ps1')) -InputText $payload -WorkingDirectory $root
    Assert-True ($result.exitCode -eq 2) "Missing CLI hook failed open (exit $($result.exitCode))"
}

foreach ($sample in @(
    @{ name = 'rm'; command = 'rm test.txt'; directory = $false },
    @{ name = 'rm recursive'; command = 'rm -rf test-folder'; directory = $true },
    @{ name = 'del'; command = 'del test.txt'; directory = $false },
    @{ name = 'erase'; command = 'erase test.txt'; directory = $false },
    @{ name = 'rmdir'; command = 'rmdir /s /q test-folder'; directory = $true },
    @{ name = 'rd'; command = 'rd /s /q test-folder'; directory = $true },
    @{ name = 'Remove-Item'; command = 'Remove-Item -LiteralPath test.txt'; directory = $false },
    @{ name = 'PowerShell wrapper'; command = 'powershell -Command "Remove-Item test.txt"'; directory = $false }
)) {
    $case = $sample
    Invoke-Case ('actual hook safe delete: ' + $case.name) {
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
        $uninstalled = Invoke-Process -Program $ShellPath -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'uninstall.ps1'), '-CodexHome', $codexHome, '-InstallDir', $installDir, '-NoPathUpdate') -WorkingDirectory $root
        Assert-True ($uninstalled.exitCode -eq 0) "Uninstall failed (exit $($uninstalled.exitCode)); see process evidence"
        Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) 'Uninstall removed existing config'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($originalBytes)) 'Uninstall did not restore config byte for byte'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hooksPath)) -eq [Convert]::ToBase64String($originalHookBytes)) 'Uninstall did not restore hooks byte for byte'
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Uninstall left installed program files behind'
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
