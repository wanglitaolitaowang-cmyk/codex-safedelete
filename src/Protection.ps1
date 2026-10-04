# The switch is installation-wide. Recovery commands never consult it.
. (Join-Path $PSScriptRoot 'InstallState.ps1')

function Read-SafeDeleteProtectionEnabled {
    param([string]$InstallDir, [switch]$RequireState)
    $path = Join-Path $InstallDir 'protection-state.json'
    Assert-SafeDeleteInstallPath $path
    if (-not (Test-Path -LiteralPath $path)) {
        if ($RequireState) { throw 'Protection state is missing.' }
        return $true # Older/source Hooks retain their existing protection.
    }
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 128) { throw 'Invalid protection state file.' }
    $text = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false,$true)))
    $match = [regex]::Match($text, '\A\s*\{\s*"enabled"\s*:\s*(?<enabled>true|false)\s*\}\s*\z')
    if (-not $match.Success) { throw 'Invalid protection state; expected one boolean enabled value.' }
    return $match.Groups['enabled'].Value -ceq 'true'
}

function Get-SafeDeleteMigratedProtectionDirectory {
    param($State, [string]$InstallDir)
    if (-not $State.PSObject.Properties['migrated_from']) { return $null }
    $directory = $State.migrated_from
    Assert-SafeDeleteInstallPath $directory
    try { $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    if (-not $item.PSIsContainer -or $directory -notin @(Get-SafeDeleteLegacyInstallCandidates)) { throw 'The migrated legacy cache has an unknown directory identity.' }
    $statePath = Join-Path $directory 'install-state.json'
    Assert-SafeDeleteInstallPath $statePath
    if (-not [IO.File]::Exists($statePath) -or (Get-Item -LiteralPath $statePath -Force).Length -gt 1048576) { throw 'The migrated legacy cache installation state is missing or invalid.' }
    $legacy = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $logical = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexSafeDelete')).TrimEnd([char[]]'\/')
    Assert-SafeDeleteInstallState $legacy $logical
    if ($legacy.phase -cne 'migrated' -or -not $legacy.PSObject.Properties['migrated_to'] -or
        $legacy.migrated_to -ne $InstallDir -or $legacy.codex_home -ne $State.codex_home -or
        $legacy.hook_command -cne (Get-SafeDeleteExpectedHookCommand $logical)) { throw 'The legacy cache does not have the matching migration markers, Codex configuration, and original Hook command.' }
    $manifest = @(Get-SafeDeleteInstallManifest)
    if (@($legacy.files).Count -ne $manifest.Count -or @($legacy.files | Select-Object -Unique).Count -ne $manifest.Count -or
        @($manifest | Where-Object { $_ -notin @($legacy.files) }).Count -gt 0) { throw 'The migrated legacy cache has an incomplete file manifest.' }
    foreach ($snapshot in $legacy.snapshots) {
        $shared = @($State.snapshots | Where-Object { $_.name -ceq $snapshot.name })[0]
        if ($shared.path -ne $snapshot.path -or $shared.existed -ne $snapshot.existed -or $shared.original_hash -ne $snapshot.original_hash) { throw 'The legacy cache and shared installation have different original configuration snapshots.' }
        if ($snapshot.existed) {
            $backup = Join-Path $directory ('backup\' + $snapshot.name)
            Assert-SafeDeleteInstallPath $backup
            if (-not [IO.File]::Exists($backup) -or (Get-SafeDeleteFileHash $backup) -ne $snapshot.original_hash) { throw ('The migrated legacy cache backup is missing or changed: ' + $snapshot.name) }
        }
    }
    $known = @('install-state.json','protection-state.json') + $manifest + @($legacy.snapshots | Where-Object existed | ForEach-Object { 'backup\' + $_.name })
    foreach ($snapshot in @($legacy.snapshots | Where-Object { $_.PSObject.Properties['installed_reference_hash'] })) {
        $referencePath = Join-Path $directory 'backup\installed-config.toml'
        Assert-SafeDeleteInstallPath $referencePath
        if (-not [IO.File]::Exists($referencePath) -or (Get-SafeDeleteFileHash $referencePath) -cne $snapshot.installed_reference_hash) { throw 'The migrated legacy cache installed-configuration reference is missing or changed.' }
        $known += 'backup\installed-config.toml'
    }
    foreach ($relative in $manifest) {
        $file = Join-Path $directory $relative
        Assert-SafeDeleteInstallPath $file
        if (-not [IO.File]::Exists($file)) { throw ('The migrated legacy cache file is missing: ' + $relative) }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Recurse -Force -ErrorAction Stop)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The migrated legacy cache contains a link.' }
        if (-not $entry.PSIsContainer -and $entry.FullName.Substring($directory.Length + 1) -notin $known) { throw 'The migrated legacy cache contains an unknown file.' }
    }
    $null = Read-SafeDeleteProtectionEnabled -InstallDir $directory -RequireState
    return $directory
}

function Invoke-SafeDeleteProtection {
    param([ValidateSet('off','on','status')][string]$Action, [string]$InstallDir)
    $originalPath = $env:Path
    $migrationLocks = @()
    $switchWrites = New-Object 'System.Collections.Generic.List[object]'
    try {
        $InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/')
        Assert-SafeDeleteInstallPath $InstallDir
        $statePath = Join-Path $InstallDir 'install-state.json'
        Assert-SafeDeleteInstallPath $statePath
        if (-not [IO.File]::Exists($statePath) -or (Get-Item -LiteralPath $statePath).Length -gt 1048576) { throw 'SafeDelete installation state is missing or invalid.' }
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-SafeDeleteInstallState $state $InstallDir
        if ($state.phase -ne 'complete' -or 'src\Protection.ps1' -notin @($state.files)) { throw 'Installation does not support pause or is incomplete.' }
        $legacyDirectory = $null
        if ($state.PSObject.Properties['migrated_from']) {
            $recordedHome = $state.codex_home
            $migrationLocks = @(Enter-SafeDeleteInstallationLocks -InstallDir $InstallDir -CodexHome $recordedHome)
            $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            Assert-SafeDeleteInstallState $state $InstallDir
            if ($state.phase -ne 'complete' -or $state.codex_home -ne $recordedHome) { throw 'Migration state changed while the protection lock was acquired.' }
            $legacyDirectory = Get-SafeDeleteMigratedProtectionDirectory -State $state -InstallDir $InstallDir
        }
        foreach ($relative in @(Get-SafeDeleteInstallManifest)) {
            $installedFile = Join-Path $InstallDir $relative
            Assert-SafeDeleteInstallPath $installedFile
            if (-not [IO.File]::Exists($installedFile)) { throw ('Installed file is missing: ' + $relative) }
        }
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $expectedCommand = "& '" + $shell.Replace("'", "''") + "' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '" + (Join-Path $InstallDir 'hooks\pre-tool-use.ps1').Replace("'", "''") + "'"
        if ($state.hook_command -cne $expectedCommand) { throw 'Unexpected SafeDelete Hook command.' }
        $activeHome = $env:CODEX_HOME
        if (-not $activeHome) { $activeHome = Join-Path $env:USERPROFILE '.codex' }
        if ([IO.Path]::GetFullPath($activeHome).TrimEnd([char[]]'\/') -ne $state.codex_home.TrimEnd([char[]]'\/')) { throw 'This installation belongs to a different Codex configuration.' }
        Assert-SafeDeleteInstallPath $state.codex_home
        $enabled = Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState:($Action -eq 'status')
        $legacyEnabled = $null
        if ($legacyDirectory) {
            $legacyEnabled = Read-SafeDeleteProtectionEnabled -InstallDir $legacyDirectory -RequireState
            if ($Action -eq 'status' -and $legacyEnabled -ne $enabled) { throw 'The cached legacy Hook and shared installation have different protection states. Run safedelete on to restore protection before restarting Codex.' }
        }
        Find-SafeDeleteCodex
        . (Join-Path $PSScriptRoot '..\hooks\Trust.ps1')
        $registration = Get-SafeDeleteHookRegistration -CodexHome $state.codex_home -WorkingDirectory ((Get-Location).Path) -HookPath (Join-Path $state.codex_home 'hooks.json') -ExpectedCommand $state.hook_command
        if (-not $registration.Enabled -or $registration.TrustStatus -notin @('trusted','managed') -or $registration.Matcher -cne '^(Bash|apply_patch)$') { throw 'SafeDelete Hook is not enabled and trusted with its original matcher.' }
        if ($Action -ne 'status') {
            $desired = $Action -eq 'on'
            $directories = @($InstallDir)
            if ($legacyDirectory) {
                # Resume cached workers first. Failed pause operations below only
                # restore previously enabled switches, preserving their protection.
                $directories = if ($desired) { @($legacyDirectory,$InstallDir) } else { @($InstallDir,$legacyDirectory) }
            }
            foreach ($directory in $directories) {
                $switchPath = Join-Path $directory 'protection-state.json'
                $before = Read-SafeDeleteProtectionEnabled -InstallDir $directory
                if ($before -ne $desired -or -not [IO.File]::Exists($switchPath)) {
                    if ($legacyDirectory) {
                        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(([pscustomobject]@{enabled=$desired} | ConvertTo-Json -Depth 30))
                        $switchWrites.Add([pscustomobject]@{path=$switchPath;was_enabled=$before;written_hash=(Get-SafeDeleteBytesHash $bytes)})
                    }
                    Write-SafeDeleteJson $switchPath ([pscustomobject]@{ enabled=$desired })
                }
                if ((Read-SafeDeleteProtectionEnabled -InstallDir $directory -RequireState) -ne $desired) { throw 'Protection state changed during the command. Check status again.' }
            }
            $enabled = Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState
            if ($enabled -ne $desired) { throw 'Protection state changed during the command. Check status again.' }
        }
        $expected = if ($enabled) { 'deny' } else { 'bypass' }
        . (Join-Path $PSScriptRoot 'Storage.ps1')
        $projectRoot = Get-SafeDeleteRoot -WorkingDirectory ((Get-Location).Path)
        Test-SafeDeleteHookCommand -HookCommand $state.hook_command -ProjectRoot $projectRoot -ExpectedDecision $expected
        if ($legacyDirectory) {
            if ((Read-SafeDeleteProtectionEnabled -InstallDir $legacyDirectory -RequireState) -ne $enabled) { throw 'The cached legacy Hook protection state changed during verification.' }
            Test-SafeDeleteHookCommand -HookCommand (Get-SafeDeleteExpectedHookCommand $legacyDirectory) -ProjectRoot $projectRoot -ExpectedDecision $expected
            if ((Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState) -ne $enabled -or
                (Read-SafeDeleteProtectionEnabled -InstallDir $legacyDirectory -RequireState) -ne $enabled) { throw 'Protection states changed while the cached and shared Hook workers were verified.' }
        }
        if ($enabled) { return 'ON' }
        return 'OFF'
    } catch {
        $message = $_.Exception.Message
        if ($Action -eq 'off' -and $switchWrites.Count -gt 0) {
            foreach ($write in $switchWrites) {
                if (-not $write.was_enabled) { continue }
                try {
                    if ((Read-SafeDeleteProtectionEnabled -InstallDir ([IO.Path]::GetDirectoryName($write.path)) -RequireState)) { continue }
                    if ((Get-SafeDeleteFileHash $write.path) -cne $write.written_hash) { throw 'A protection switch changed outside this command; its contents were preserved.' }
                    Write-SafeDeleteJson $write.path ([pscustomobject]@{enabled=$true})
                } catch { $message += ' Restoring previous ON protection could not be verified: ' + $_.Exception.Message }
            }
        }
        if ($switchWrites.Count -gt 0) { $message += ' Protection synchronization is incomplete; existing ON protection was preserved where possible. Verify both installations before relying on the status.' }
        [Console]::Error.WriteLine('Codex SafeDelete: ' + $message)
        return 'UNKNOWN'
    } finally {
        Exit-SafeDeleteInstallationLocks $migrationLocks
        $env:Path = $originalPath
    }
}
