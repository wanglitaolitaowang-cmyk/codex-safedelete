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

function Invoke-SafeDeleteProtection {
    param([ValidateSet('off','on','status')][string]$Action, [string]$InstallDir)
    $originalPath = $env:Path
    try {
        $InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/')
        Assert-SafeDeleteInstallPath $InstallDir
        $statePath = Join-Path $InstallDir 'install-state.json'
        Assert-SafeDeleteInstallPath $statePath
        if (-not [IO.File]::Exists($statePath) -or (Get-Item -LiteralPath $statePath).Length -gt 1048576) { throw 'SafeDelete installation state is missing or invalid.' }
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-SafeDeleteInstallState $state $InstallDir
        if ($state.phase -ne 'complete' -or 'src\Protection.ps1' -notin @($state.files)) { throw 'Installation does not support pause or is incomplete.' }
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
        Find-SafeDeleteCodex
        . (Join-Path $PSScriptRoot '..\hooks\Trust.ps1')
        $registration = Get-SafeDeleteHookRegistration -CodexHome $state.codex_home -WorkingDirectory ((Get-Location).Path) -HookPath (Join-Path $state.codex_home 'hooks.json') -ExpectedCommand $state.hook_command
        if (-not $registration.Enabled -or $registration.TrustStatus -notin @('trusted','managed') -or $registration.Matcher -cne '^(Bash|apply_patch)$') { throw 'SafeDelete Hook is not enabled and trusted with its original matcher.' }
        if ($Action -ne 'status') {
            $desired = $Action -eq 'on'
            $switchPath = Join-Path $InstallDir 'protection-state.json'
            if ($enabled -ne $desired -or -not [IO.File]::Exists($switchPath)) {
                Write-SafeDeleteJson $switchPath ([pscustomobject]@{ enabled=$desired })
            }
            $enabled = Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState
            if ($enabled -ne $desired) { throw 'Protection state changed during the command. Check status again.' }
        }
        $expected = if ($enabled) { 'deny' } else { 'bypass' }
        . (Join-Path $PSScriptRoot 'Storage.ps1')
        $projectRoot = Get-SafeDeleteRoot -WorkingDirectory ((Get-Location).Path)
        Test-SafeDeleteHookCommand -HookCommand $state.hook_command -ProjectRoot $projectRoot -ExpectedDecision $expected
        if ($enabled) { return 'ON' }
        return 'OFF'
    } catch {
        [Console]::Error.WriteLine('Codex SafeDelete: ' + $_.Exception.Message)
        return 'UNKNOWN'
    } finally { $env:Path = $originalPath }
}
