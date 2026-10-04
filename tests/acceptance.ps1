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
