[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$InstallDir,
    [switch]$NoPathUpdate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'src\InstallState.ps1')
Assert-SafeDeleteSupportedInstallRuntime
. (Join-Path $PSScriptRoot 'hooks\Trust.ps1')
. (Join-Path $PSScriptRoot 'src\Storage.ps1')
. (Join-Path $PSScriptRoot 'src\Protection.ps1')

if (-not $CodexHome) { $CodexHome = $env:CODEX_HOME }
if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'CodexSafeDelete' }
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/')
$project = Get-SafeDeleteRoot -WorkingDirectory ((Get-Location).Path)
$project = Get-SDProjectRoot -ProjectRoot $project
Assert-SafeDeleteInstallPath $InstallDir
Assert-SafeDeleteInstallPath $CodexHome
Assert-SDNoReparse $InstallDir
Assert-SDNoReparse $CodexHome
if ($CodexHome -eq $InstallDir -or $CodexHome.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase) -or $InstallDir.StartsWith($CodexHome + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'InstallDir and CodexHome must be separate directories.' }
$installationLocks = @(Enter-SafeDeleteInstallationLocks -InstallDir $InstallDir -CodexHome $CodexHome)
try {
    $originalProcessPath = $env:Path
    $statePath = Join-Path $InstallDir 'install-state.json'
    if (Test-Path -LiteralPath $statePath) {
        $existing = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-SafeDeleteInstallState $existing $InstallDir
        if ($existing.phase -ne 'complete' -or $existing.codex_home -ne $CodexHome -or $existing.install_dir -ne $InstallDir) { throw 'An incomplete or different installation exists. Inspect install-state.json first.' }
        $runtimeFiles = @(Get-SafeDeleteInstallManifest | Where-Object { $_.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase) -or $_ -ceq 'SKILL.md' })
        foreach ($relative in $runtimeFiles) {
            $sourceHash = Get-SafeDeleteFileHash (Join-Path $PSScriptRoot $relative)
            $installedHash = Get-SafeDeleteFileHash (Join-Path $InstallDir $relative)
            if (-not $sourceHash -or -not $installedHash -or $sourceHash -cne $installedHash) {
                throw ('Installed files differ: ' + $relative + '. Repeated installation does not upgrade; run the original Uninstall SafeDelete.cmd, then install this version.')
            }
        }
        Find-SafeDeleteCodex
        $registration = Get-SafeDeleteHookRegistration -CodexHome $CodexHome -WorkingDirectory $project -HookPath (Join-Path $CodexHome 'hooks.json') -ExpectedCommand $existing.hook_command
        if ($registration.TrustStatus -notin @('trusted','managed')) { throw 'Hook trust changed. Check Codex /hooks before continuing.' }
        $expected = if (Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState) { 'deny' } else { 'bypass' }
        Test-SafeDeleteHookCommand -HookCommand $existing.hook_command -ProjectRoot $project -ExpectedDecision $expected
        $null = Initialize-SafeDeleteStore -ProjectRoot $project
        Write-Output 'Codex SafeDelete installed. (Already installed and verified; existing files were not updated.)'
        exit 0
    }
    if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) { throw 'InstallDir must be empty; existing files will not be overwritten.' }
    if ($InstallDir -eq $PSScriptRoot -or $PSScriptRoot.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'InstallDir must not contain the source checkout.' }
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hookScript = Join-Path $InstallDir 'hooks\pre-tool-use.ps1'
    $expectedHookCommand = "& '" + $shell.Replace("'", "''") + "' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '" + $hookScript.Replace("'", "''") + "'"
    $hookFile = Join-Path $CodexHome 'hooks.json'
    $snapshots = @()
    # Validate and read both originals before creating installation/backup files.
    # A directory, link or unreadable config.toml must not leave a partial install.
    foreach ($name in @('config.toml', 'hooks.json')) {
        $path = Join-Path $CodexHome $name
        Assert-SafeDeleteInstallPath $path
        Assert-SDNoReparse $path
        $exists = Test-SDExists $path
        if ($exists -and -not [IO.File]::Exists($path)) { throw ($name + ' must be a regular file.') }
        $snapshots += [pscustomobject]@{ name=$name; path=$path; existed=$exists; original_hash=(Get-SafeDeleteFileHash $path); installed_hash=$null }
    }
    $configuration = [pscustomobject]@{ hooks = [pscustomobject]@{} }
    if (Test-Path -LiteralPath $hookFile) {
        if (-not [IO.File]::Exists($hookFile)) { throw 'hooks.json must be a regular file.' }
        Assert-SafeDeleteInstallPath $hookFile
        if ((Get-Item -LiteralPath $hookFile -Force).Length -gt 1048576) { throw 'hooks.json exceeds the 1 MiB installation limit.' }
        $configurationJson = [IO.File]::ReadAllText($hookFile)
        # Windows PowerShell enumerates a top-level single-element JSON array.
        # Check the root token as well as the parsed type to keep it an object.
        if (-not $configurationJson.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'hooks.json must be a JSON object.' }
        $configuration = $configurationJson | ConvertFrom-Json
    }
    if ($configuration -isnot [pscustomobject]) { throw 'hooks.json must be a JSON object.' }
    if (-not $configuration.PSObject.Properties['hooks']) { $configuration | Add-Member NoteProperty hooks ([pscustomobject]@{}) }
    if ($configuration.hooks -isnot [pscustomobject]) { throw 'hooks.json hooks must be an object.' }
    $prior = @()
    if ($configuration.hooks.PSObject.Properties['PreToolUse']) {
        if ($configuration.hooks.PreToolUse -isnot [array]) { throw 'hooks.json PreToolUse must be an array.' }
        $prior = @($configuration.hooks.PreToolUse)
    }
    $orphanCount = 0
    foreach ($group in $prior) {
        if ($group -isnot [pscustomobject] -or -not $group.PSObject.Properties['hooks'] -or $group.hooks -isnot [array]) {
            throw 'hooks.json PreToolUse entries must be objects containing a hooks array.'
        }
        foreach ($commandHook in $group.hooks) {
            if ($commandHook -isnot [pscustomobject]) { throw 'hooks.json PreToolUse hooks must be JSON objects.' }
            if ($commandHook.PSObject.Properties['command']) {
                if ($commandHook.command -isnot [string]) { throw 'hooks.json PreToolUse command fields must be strings.' }
                if ($commandHook.command -ceq $expectedHookCommand) { $orphanCount++ }
            }
        }
    }
    if ($orphanCount -gt 0) {
        throw ('SafeDelete is already registered without matching installation state (' + $orphanCount + ' hooks). No changes were made. Restore the original installation or resolve the orphan registration before installing.')
    }
    Find-SafeDeleteCodex
    $state = [pscustomobject]@{
        version = 1; phase = 'installing'; install_dir = $InstallDir; codex_home = $CodexHome
        hook_command = ''; snapshots = $snapshots; files = @(); path_updated = $false
        original_user_path = [Environment]::GetEnvironmentVariable('Path','User')
        original_process_path = $originalProcessPath; installed_user_path = $null
    }
    $backupDirectory = Join-Path $InstallDir 'backup'
    $createdInstallDirectory = -not (Test-SDExists $InstallDir)
    $createdBackupDirectory = -not (Test-SDExists $backupDirectory)
    $attemptedBackups = New-Object 'System.Collections.Generic.List[string]'
    $preparationComplete = $false
    try {
        $null = New-Item -ItemType Directory -Path $InstallDir -Force
        $null = New-Item -ItemType Directory -Path $backupDirectory -Force
        $null = New-Item -ItemType Directory -Path $CodexHome -Force
        foreach ($snapshot in @($state.snapshots | Where-Object existed)) {
            Assert-SafeDeleteInstallPath $snapshot.path
            Assert-SDNoReparse $snapshot.path
            $backup = Join-Path $backupDirectory $snapshot.name
            Assert-SafeDeleteInstallPath $backup
            Assert-SDNoReparse $backup
            if (Test-SDExists $backup) { throw ('Unexpected pre-existing backup: ' + $snapshot.name) }
            $attemptedBackups.Add($backup)
            Copy-Item -LiteralPath $snapshot.path -Destination $backup
            if ((Get-SafeDeleteFileHash $backup) -cne $snapshot.original_hash) { throw ('Configuration changed while preparing backup: ' + $snapshot.name) }
        }
        Write-SafeDeleteJson $statePath $state
        $preparationComplete = $true
        $manifest = @(Get-SafeDeleteInstallManifest)
        $state.files = $manifest
        foreach ($relative in $manifest) {
            if ($relative -eq 'safedelete.cmd') { continue }
            $target = Join-Path $InstallDir $relative
            $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $target
        }
        Write-SafeDeleteJson (Join-Path $InstallDir 'protection-state.json') ([pscustomobject]@{ enabled=$true })
        $shim = '@echo off' + "`r`n" + '"' + $shell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0src\safedelete.ps1" %*' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $InstallDir 'safedelete.cmd'), $shim, [Text.Encoding]::Default)
        $state.hook_command = $expectedHookCommand
        $entry = [pscustomobject]@{ matcher='^(Bash|apply_patch)$'; hooks=@([pscustomobject]@{ type='command'; command=$state.hook_command; timeout=30; statusMessage='Codex SafeDelete' }) }
        $configuration.hooks | Add-Member NoteProperty PreToolUse @($prior + $entry) -Force
        Write-SafeDeleteJson $hookFile $configuration
        $registration = Get-SafeDeleteHookRegistration -CodexHome $CodexHome -WorkingDirectory $project -HookPath $hookFile -ExpectedCommand $state.hook_command -Trust
        if ($registration.TrustStatus -notin @('trusted','managed') -or -not $registration.Enabled) { throw 'Codex did not verify the hook as enabled and trusted.' }
        Test-SafeDeleteHookCommand -HookCommand $state.hook_command -ProjectRoot $project
        $null = Initialize-SafeDeleteStore -ProjectRoot $project
        if (-not $NoPathUpdate) {
            $userPath = $state.original_user_path
            if (@($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $InstallDir }).Count -eq 0) {
                $state.installed_user_path = (($userPath, $InstallDir) | Where-Object { $_ }) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $state.installed_user_path, 'User')
                $state.path_updated = $true
            } else { $state.installed_user_path = $userPath }
            $env:Path = $InstallDir + ';' + $env:Path
        }
        foreach ($snapshot in $state.snapshots) { $snapshot.installed_hash = Get-SafeDeleteFileHash $snapshot.path }
        $state.phase = 'complete'
        Write-SafeDeleteJson $statePath $state
        Write-Output 'Codex SafeDelete installed.'
        Write-Output "`nProtected:"
        foreach ($name in @('Remove-Item','rm','del','rmdir','git clean','git reset --hard')) { Write-Output (([char]0x2713).ToString() + ' ' + $name) }
        Write-Output "`nUndo:`nsafedelete undo"
        Write-Output "`nRestart Codex and open a new terminal. In Codex /hooks, confirm SafeDelete is enabled and trusted."
    } catch {
        $failure = $_
        if (-not $preparationComplete -and -not (Test-SDExists $statePath)) {
            # No configuration or PATH was written. Remove only known backups that
            # this attempt started and owned empty directories; never restore without
            # complete backups, and never recursively delete an installation tree.
            $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
            foreach ($backup in $attemptedBackups) {
                try {
                    if (-not (Test-SDWithin ([IO.Path]::GetFullPath($backup)) $InstallDir)) { throw 'Backup cleanup escaped InstallDir.' }
                    Assert-SafeDeleteInstallPath $backup
                    Assert-SDNoReparse $backup
                    if (Test-SDExists $backup) {
                        if (-not [IO.File]::Exists($backup)) { throw 'Backup cleanup requires a regular file.' }
                        [IO.File]::Delete($backup)
                    }
                } catch { $cleanupErrors.Add($_.Exception.Message) }
            }
            foreach ($directory in @(
                [pscustomobject]@{ path=$backupDirectory; owned=$createdBackupDirectory },
                [pscustomobject]@{ path=$InstallDir; owned=$createdInstallDirectory })) {
                if (-not $directory.owned) { continue }
                try {
                    $absoluteDirectory = [IO.Path]::GetFullPath($directory.path)
                    if ($absoluteDirectory -ne $InstallDir -and -not (Test-SDWithin $absoluteDirectory $InstallDir)) { throw 'Directory cleanup escaped InstallDir.' }
                    Assert-SafeDeleteInstallPath $directory.path
                    Assert-SDNoReparse $directory.path
                    if (Test-SDExists $directory.path) {
                        if (-not (Get-SDItem $directory.path).PSIsContainer) { throw 'Cleanup requires an owned directory.' }
                        if (@([IO.Directory]::EnumerateFileSystemEntries($directory.path)).Count -gt 0) { throw ('Cleanup preserved nonempty directory: ' + $directory.path) }
                        [IO.Directory]::Delete($directory.path)
                    }
                } catch { $cleanupErrors.Add($_.Exception.Message) }
            }
            if ($cleanupErrors.Count -gt 0) {
                throw ('Installation preparation failed before configuration or User PATH changes. Automatic cleanup could not complete; preserve and inspect ' + $InstallDir + '. ' + ($cleanupErrors -join ' ') + ' Original error: ' + $failure.Exception.Message)
            }
            throw $failure
        }
        # Persist the uncertain phase before restoring anything. A failed rollback or
        # final state write must never leave a state that permits normal uninstall.
        $state.phase = 'rolling-back'
        Write-SafeDeleteJson $statePath $state
        Restore-SafeDeleteConfiguration -State $state -InstallDir $InstallDir
        $state.phase = 'rolled-back'
        Write-SafeDeleteJson $statePath $state
        throw $failure
    }
} finally {
    Exit-SafeDeleteInstallationLocks $installationLocks
}
