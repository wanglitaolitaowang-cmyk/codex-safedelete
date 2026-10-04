# Codex's local app-server supplies hook identity and hash; do not reimplement its hash.
# Dot-source this file. This talks only to a local stdio process, never to a model.

function Start-SafeDeleteHookServer {
    param([string]$CodexHome, [string]$WorkingDirectory, [switch]$EnableHooks)
    $codex = Get-Command codex -ErrorAction Stop
    if ([System.IO.Path]::GetExtension($codex.Source) -ne '.exe') {
        throw 'SafeDelete requires codex.exe on PATH for local hook verification. Use the executable bundled with Codex Desktop.'
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $codex.Source
    $start.Arguments = 'app-server --stdio --strict-config'
    if ($EnableHooks) { $start.Arguments += ' -c features.hooks=true' }
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Cannot start the local Codex app-server.' }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $inputWriter = New-Object System.IO.StreamWriter -ArgumentList ($process.StandardInput.BaseStream, $utf8)
    $inputWriter.AutoFlush = $true
    $server = [pscustomobject]@{ Process = $process; Input = $inputWriter; NextId = 1; Errors = $process.StandardError.ReadToEndAsync() }
    try {
        $null = Invoke-SafeDeleteHookRpc $server 'initialize' @{
            clientInfo = @{ name = 'codex-safedelete'; version = '0.1.0' }
            capabilities = @{ experimentalApi = $true }
        }
        $server.Input.WriteLine('{"method":"initialized"}')
        return $server
    } catch {
        Stop-SafeDeleteHookServer $server
        throw
    }
}

function Invoke-SafeDeleteHookRpc {
    param($Server, [string]$Method, [hashtable]$Params)
    $id = $Server.NextId
    $Server.NextId++
    $request = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 30 -Compress
    $Server.Input.WriteLine($request)
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $read = $Server.Process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $read.Wait($remaining)) { throw "Local Codex app-server timed out during $Method." }
        $line = $read.Result
        if ($null -eq $line) {
            $reason = ''
            if ($Server.Errors.IsCompleted) { $reason = $Server.Errors.Result }
            throw "Local Codex app-server closed during $Method. $reason"
        }
        $message = $line | ConvertFrom-Json -ErrorAction Stop
        if ($message.PSObject.Properties['id'] -and $message.id -eq $id) {
            if ($message.PSObject.Properties['error']) {
                throw "Codex app-server rejected ${Method}: $($message.error.message) (code $($message.error.code))."
            }
            return $message.result
        }
        # Notifications carry no request result and need no response here.
    }
    throw "Local Codex app-server timed out during $Method."
}

function Stop-SafeDeleteHookServer {
    param($Server)
    if ($null -eq $Server) { return }
    try {
        $Server.Input.Close()
        if (-not $Server.Process.WaitForExit(2000)) { $Server.Process.Kill(); $null = $Server.Process.WaitForExit(2000) }
    } finally { $Server.Process.Dispose() }
}

function Test-SafeDeleteHookMetadataEqual {
    param($Left, $Right, [int]$Depth = 0, [string[]]$IgnoredProperties = @())
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Depth -gt 8 -or $Left.GetType() -ne $Right.GetType()) { return $false }
    if ($Left -is [string]) { return [string]::Equals($Left, $Right, [StringComparison]::Ordinal) }
    if ($Left -is [System.Collections.IList]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (-not (Test-SafeDeleteHookMetadataEqual $Left[$i] $Right[$i] ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Left -is [System.Management.Automation.PSCustomObject]) {
        $leftProperties = @($Left.PSObject.Properties | Where-Object { $IgnoredProperties -cnotcontains $_.Name })
        $rightProperties = @($Right.PSObject.Properties | Where-Object { $IgnoredProperties -cnotcontains $_.Name })
        if ($leftProperties.Count -ne $rightProperties.Count) { return $false }
        foreach ($property in $leftProperties) {
            $matches = @($rightProperties | Where-Object { [string]::Equals($_.Name, $property.Name, [StringComparison]::Ordinal) })
            if ($matches.Count -ne 1 -or
                -not (Test-SafeDeleteHookMetadataEqual $property.Value $matches[0].Value ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Left -is [ValueType]) { return $Left.Equals($Right) }
    return $false
}

function Assert-SafeDeleteHookMetadata {
    param($Hook, [string]$WorkingDirectory, [string]$HookPath)
    foreach ($name in @('key','currentHash','sourcePath','eventName','command','matcher','trustStatus')) {
        $property = $Hook.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($property.Value)) {
            throw "Invalid SafeDelete Hook metadata ($name); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
    if ($Hook.currentHash -cnotmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw "Invalid SafeDelete Hook metadata (currentHash); cwd=$WorkingDirectory; source=$HookPath."
    }
    $enabled = $Hook.PSObject.Properties['enabled']
    if ($null -eq $enabled -or $enabled.Value -isnot [bool]) {
        throw "Invalid SafeDelete Hook metadata (enabled must be boolean); cwd=$WorkingDirectory; source=$HookPath."
    }
    foreach ($name in @('async','isManaged')) {
        $property = $Hook.PSObject.Properties[$name]
        if ($null -ne $property -and $property.Value -isnot [bool]) {
            throw "Invalid SafeDelete Hook metadata ($name must be boolean); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
    foreach ($name in @('handlerType','source')) {
        $property = $Hook.PSObject.Properties[$name]
        if ($null -ne $property -and ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value))) {
            throw "Invalid SafeDelete Hook metadata ($name must be a string); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
    foreach ($name in @('statusMessage','pluginId')) {
        $property = $Hook.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and $property.Value -isnot [string]) {
            throw "Invalid SafeDelete Hook metadata ($name must be a string or null); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
    foreach ($name in @('timeoutSec','additionalContextLimit','displayOrder')) {
        $property = $Hook.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and
            (($property.Value -isnot [int] -and $property.Value -isnot [long]) -or $property.Value -lt 0)) {
            throw "Invalid SafeDelete Hook metadata ($name must be a non-negative integer or null); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
}

function Select-SafeDeleteHookRegistration {
    param($Listing, [string]$WorkingDirectory, [string]$HookPath, [string]$ExpectedCommand)
    if ($null -eq $Listing -or -not $Listing.PSObject.Properties['data']) { throw 'Codex returned an invalid hooks/list response.' }
    # Only this requested cwd is relevant. Another project's rows cannot supply
    # a registration, introduce a duplicate, or hide configuration errors here.
    $entries = @($Listing.data | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['cwd'] -and $_.cwd -is [string] -and
        [string]::Equals($_.cwd, $WorkingDirectory, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($entries.Count -eq 0) { throw "Codex returned no Hook listing for cwd=$WorkingDirectory; source=$HookPath." }
    foreach ($entry in $entries) {
        if (-not $entry.PSObject.Properties['hooks'] -or -not $entry.PSObject.Properties['errors']) {
            throw "Codex returned an invalid Hook listing for cwd=$WorkingDirectory; source=$HookPath."
        }
        if (@($entry.errors).Count -gt 0) {
            throw "Codex hook configuration has $(@($entry.errors).Count) error(s); cwd=$WorkingDirectory; source=$HookPath."
        }
    }
    $allHooks = @($entries | ForEach-Object { $_.hooks } | Where-Object { $null -ne $_ })
    $candidates = @($allHooks | Where-Object {
        $_.PSObject.Properties['sourcePath'] -and $_.sourcePath -is [string] -and
        [string]::Equals($_.sourcePath, $HookPath, [StringComparison]::OrdinalIgnoreCase) -and
        $_.PSObject.Properties['eventName'] -and $_.eventName -is [string] -and
        [string]::Equals($_.eventName, 'preToolUse', [StringComparison]::Ordinal) -and
        $_.PSObject.Properties['command'] -and $_.command -is [string] -and
        [string]::Equals($_.command, $ExpectedCommand, [StringComparison]::Ordinal)
    })
    $byKey = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($hook in $candidates) {
        Assert-SafeDeleteHookMetadata $hook $WorkingDirectory $HookPath
        if ($byKey.ContainsKey($hook.key)) {
            if (-not (Test-SafeDeleteHookMetadataEqual $byKey[$hook.key] $hook)) {
                throw "Conflicting SafeDelete Hook rows; cwd=$WorkingDirectory; source=$HookPath; key=$($hook.key)."
            }
        } else { $byKey.Add($hook.key, $hook) }
    }
    # Check every row with a candidate key, including a conflicting row whose
    # command/source/event differs enough that it was not a candidate itself.
    foreach ($hook in $allHooks) {
        $key = $hook.PSObject.Properties['key']
        if ($null -ne $key -and $key.Value -is [string] -and $byKey.ContainsKey($key.Value)) {
            Assert-SafeDeleteHookMetadata $hook $WorkingDirectory $HookPath
            if (-not (Test-SafeDeleteHookMetadataEqual $byKey[$key.Value] $hook)) {
                throw "Conflicting SafeDelete Hook rows; cwd=$WorkingDirectory; source=$HookPath; key=$($key.Value)."
            }
        }
    }
    if ($byKey.Count -ne 1) {
        $keys = @($byKey.Keys) -join '; '
        throw "Expected exactly one SafeDelete PreToolUse hook; Codex discovered $($byKey.Count) distinct registration(s); cwd=$WorkingDirectory; source=$HookPath; keys=$keys."
    }
    foreach ($hook in $byKey.Values) {
        if (-not $hook.enabled) { throw "The SafeDelete hook is disabled; cwd=$WorkingDirectory; source=$HookPath; key=$($hook.key)." }
        return $hook
    }
}

function Get-SafeDeleteHookRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [switch]$Trust
    )
    $CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
    $WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    $HookPath = [System.IO.Path]::GetFullPath($HookPath)
    $server = $null
    try {
        $server = Start-SafeDeleteHookServer $CodexHome $WorkingDirectory -EnableHooks:$Trust
        $listing = Invoke-SafeDeleteHookRpc $server 'hooks/list' @{ cwds = @($WorkingDirectory) }
        $hook = Select-SafeDeleteHookRegistration $listing $WorkingDirectory $HookPath $ExpectedCommand
        if ($Trust) {
            $state = @{}
            $state[$hook.key] = @{ trusted_hash = $hook.currentHash }
            $null = Invoke-SafeDeleteHookRpc $server 'config/batchWrite' @{
                edits = @(
                    @{ keyPath = 'features.hooks'; value = $true; mergeStrategy = 'upsert' },
                    @{ keyPath = 'hooks.state'; value = $state; mergeStrategy = 'upsert' }
                )
            }
            # Reload from disk without a flag override before confirming protection.
            Stop-SafeDeleteHookServer $server
            $server = $null
            $server = Start-SafeDeleteHookServer $CodexHome $WorkingDirectory
            $after = Invoke-SafeDeleteHookRpc $server 'hooks/list' @{ cwds = @($WorkingDirectory) }
            $verified = Select-SafeDeleteHookRegistration $after $WorkingDirectory $HookPath $ExpectedCommand
            if (-not (Test-SafeDeleteHookMetadataEqual $hook $verified -IgnoredProperties @('trustStatus')) -or
                $verified.trustStatus -cne 'trusted') {
                throw 'Codex did not confirm the same SafeDelete hook as enabled and trusted.'
            }
            $hook = $verified
        }
        return [pscustomobject]@{
            Key = $hook.key; CurrentHash = $hook.currentHash; TrustStatus = $hook.trustStatus
            Enabled = $hook.enabled; Matcher = $hook.matcher; SourcePath = $hook.sourcePath
        }
    } finally { Stop-SafeDeleteHookServer $server }
}
