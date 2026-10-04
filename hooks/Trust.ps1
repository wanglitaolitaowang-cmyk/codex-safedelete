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
        $errors = @($listing.data | ForEach-Object { $_.errors })
        if ($errors.Count -gt 0) {
            throw ('Codex hook configuration has errors: ' + (($errors | ForEach-Object { "$($_.path): $($_.message)" }) -join '; '))
        }
        $hooks = @($listing.data | ForEach-Object { $_.hooks } | Where-Object {
            $_.sourcePath -eq $HookPath -and $_.eventName -eq 'preToolUse' -and $_.command -ceq $ExpectedCommand
        })
        if ($hooks.Count -ne 1) { throw "Expected exactly one SafeDelete PreToolUse hook; Codex discovered $($hooks.Count)." }
        $hook = $hooks[0]
        if (-not $hook.enabled) { throw 'The SafeDelete hook is disabled by the current Codex configuration.' }
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
            $verified = @($after.data | ForEach-Object { $_.hooks } | Where-Object { $_.key -ceq $hook.key })
            if ($verified.Count -ne 1 -or $verified[0].currentHash -cne $hook.currentHash -or
                $verified[0].trustStatus -ne 'trusted' -or -not $verified[0].enabled) {
                throw 'Codex did not confirm the same SafeDelete hook as enabled and trusted.'
            }
            $hook = $verified[0]
        }
        return [pscustomobject]@{
            Key = $hook.key; CurrentHash = $hook.currentHash; TrustStatus = $hook.trustStatus
            Enabled = $hook.enabled; Matcher = $hook.matcher; SourcePath = $hook.sourcePath
        }
    } finally { Stop-SafeDeleteHookServer $server }
}
