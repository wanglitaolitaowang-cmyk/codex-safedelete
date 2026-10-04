[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('delete','undo','list','restore','hook','doctor','off','on','status')][string]$Action = 'list',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Paths = @(),
    [string]$Id,
    [string]$ProjectRoot,
    [string]$Command
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Set-StrictMode -Version 2.0

function Write-HookDecision {
    param([string]$Reason, [string]$Replacement)
    if (-not $Reason) { [Console]::Out.WriteLine('{}'); return }
    $result = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } }
    if ($Replacement) {
        $result.hookSpecificOutput.permissionDecision = 'allow'
        $result.hookSpecificOutput.updatedInput = @{ command = $Replacement }
        $result.systemMessage = $Reason
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5 -Compress))
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This MVP supports Windows only. Linux and macOS are unsupported; no deletion or recovery was attempted.'
    }
    if ($Action -in @('off','on','status')) {
        $result = 'UNKNOWN'
        try {
            . (Join-Path $PSScriptRoot 'Protection.ps1')
            if ($Paths.Count -gt 0 -or $Id -or $ProjectRoot -or $Command) { throw ('Usage: safedelete ' + $Action) }
            $result = Invoke-SafeDeleteProtection -Action $Action -InstallDir (Split-Path -Parent $PSScriptRoot)
        } catch { [Console]::Error.WriteLine('Codex SafeDelete: ' + $_.Exception.Message) }
        Write-Output ('SafeDelete: ' + $result)
        Write-Output ''
        switch ($result) {
            'ON' { Write-Output 'Codex delete protection is active.' }
            'OFF' { Write-Output 'Codex delete protection is currently disabled.' }
            default { Write-Output 'Configuration requires attention.'; exit 1 }
        }
        exit 0
    }
    . (Join-Path $PSScriptRoot 'Storage.ps1')
    . (Join-Path $PSScriptRoot 'Commands.ps1')
    if ($Action -eq 'hook') {
        # Bound stdin, fail closed on invalid requests. No code from the request is executed.
        $buffer = New-Object char[] 1048577
        $length = 0
        while ($length -lt $buffer.Length) {
            $read = [Console]::In.Read($buffer, $length, $buffer.Length - $length)
            if ($read -eq 0) { break }; $length += $read
        }
        if ($length -gt 1048576) { throw 'Hook input exceeds 1 MiB.' }
        $inputText = [string]::new($buffer, 0, $length)
        $request = $inputText | ConvertFrom-Json
        if ($request.hook_event_name -ne 'PreToolUse') { throw 'Unsupported hook event.' }
        if ($request.tool_name -eq 'apply_patch') {
            $patchText = ''
            if ($request.tool_input -is [string]) { $patchText = $request.tool_input }
            elseif ($request.tool_input.PSObject.Properties['command']) { $patchText = [string]$request.tool_input.command }
            else { throw 'Missing patch text.' }
            if ($patchText -match '(?m)^\*\*\* Delete File:') {
                Write-HookDecision (([char]0x26A0).ToString() + " Codex SafeDelete`nDENY: apply_patch file deletion. Use safedelete delete <path> to keep it recoverable.")
            } else { Write-HookDecision }
            exit 0
        }
        if ($request.tool_name -notin @('Bash','exec_command','shell_command')) { Write-HookDecision; exit 0 }
        $data = $request.tool_input
        $shellCommand = $null
        if ($data.PSObject.Properties['command']) { $shellCommand = [string]$data.command }
        elseif ($data.PSObject.Properties['cmd']) { $shellCommand = [string]$data.cmd }
        if ([string]::IsNullOrWhiteSpace($shellCommand)) { throw 'Missing shell command.' }
        $cwd = [IO.Path]::GetFullPath([string]$request.cwd)
        $root = Get-SafeDeleteRoot -WorkingDirectory $cwd
        $working = $cwd
        if ($data.PSObject.Properties['workdir'] -and $data.workdir) {
            if ([IO.Path]::IsPathRooted([string]$data.workdir)) { $working = [IO.Path]::GetFullPath([string]$data.workdir) }
            else { $working = [IO.Path]::GetFullPath((Join-Path $cwd ([string]$data.workdir))) }
        }
        $shellHint = ''
        if ($data.PSObject.Properties['shell'] -and $data.shell) { $shellHint = [string]$data.shell }
        $plan = Get-SafeDeleteCommandPlan -Command $shellCommand -WorkingDirectory $working -ProjectRoot $root -Shell $shellHint
        if ($plan.action -eq 'allow') { Write-HookDecision; exit 0 }
        $notice = ([char]0x26A0).ToString() + ' Codex SafeDelete'
        if ($plan.action -eq 'deny') {
            Write-HookDecision ($notice + "`nDENY: " + $plan.reason + "`nCommand: " + $shellCommand); exit 0
        }
        # Codex 0.160 sends session cwd, not exec_command's actual workdir. Rewriting
        # makes the CLI resolve literal paths in the real tool process directory.
        $quote = { param([string]$value) "'" + $value.Replace("'", "''") + "'" }
        $cliPath = Join-Path $PSScriptRoot 'safedelete.ps1'
        $literalArgs = @($plan.literal_paths | ForEach-Object { & $quote $_ }) -join ','
        $inner = '& ' + (& $quote $cliPath) + ' -Action delete -ProjectRoot ' + (& $quote $root) +
            ' -Paths @(' + $literalArgs + ') -Command ' + (& $quote $shellCommand)
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $replacement = '& ' + (& $quote $shell) + ' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (& $quote $inner)
        $message = $notice + "`nPaths (resolved at execution):`n" + ($plan.literal_paths -join "`n") + "`nRisk: " + $plan.risk +
            "`nOriginal permanent delete BLOCKED -> replaced with safedelete delete.`nRestore: safedelete undo"
        Write-HookDecision -Reason $message -Replacement $replacement
        exit 0
    }
    if (-not $ProjectRoot) { $ProjectRoot = Get-SafeDeleteRoot -WorkingDirectory ((Get-Location).Path) }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    switch ($Action) {
        'delete' {
            if ($Paths.Count -eq 0) { throw 'Usage: safedelete delete <path> [path ...]' }
            $absolute = @($Paths | ForEach-Object {
                if ($_ -match '[*?\[\]]|^~|^\w+::|^[a-zA-Z]+:(?![\\/])') { throw 'Use explicit local paths.' }
                if ([IO.Path]::IsPathRooted($_)) { [IO.Path]::GetFullPath($_) }
                else { [IO.Path]::GetFullPath((Join-Path ((Get-Location).Path) $_)) }
            })
            if (-not $Command) { $Command = 'safedelete delete ' + ($Paths -join ' ') }
            Write-Output (([char]0x26A0).ToString() + " Codex SafeDelete`nPaths:`n" + ($absolute -join "`n") + "`nRisk: Delete file / directory")
            $record = Move-SafeDeleteItems -ProjectRoot $ProjectRoot -Paths $absolute -Command $Command
            Write-Output ('Moved to recoverable trash. Record: ' + $record.id)
            Write-Output 'Undo: safedelete undo'
        }
        'undo' {
            $record = Restore-SafeDeleteRecord -ProjectRoot $ProjectRoot
            Write-Output ('Restored: ' + $record.id)
        }
        'restore' {
            if (-not $Id -and $Paths.Count -eq 1) { $Id = $Paths[0] }
            if (-not $Id) { throw 'Usage: safedelete restore <id>' }
            $record = Restore-SafeDeleteRecord -ProjectRoot $ProjectRoot -Id $Id
            Write-Output ('Restored: ' + $record.id)
        }
        'list' {
            $history = @(Get-SafeDeleteHistory -ProjectRoot $ProjectRoot)
            if ($history.Count -eq 0) { Write-Output 'No deletion records.' }
            else {
                foreach ($entry in $history) {
                    Write-Output ($entry.id + '  ' + $entry.deleted_at + '  ' + $entry.status)
                    foreach ($item in $entry.items) { Write-Output ('  ' + $item.original_path) }
                }
            }
        }
        'doctor' {
            $null = Initialize-SafeDeleteStore -ProjectRoot $ProjectRoot
            Write-Output ('Local trash ready: ' + (Join-Path $ProjectRoot '.codex-safedelete\trash'))
            Write-Output 'Hook activation must also be verified by the installer / Codex /hooks.'
        }
    }
    exit 0
} catch {
    if ($Action -eq 'hook') { Write-HookDecision (([char]0x26A0).ToString() + " Codex SafeDelete`nDENY: " + $_.Exception.Message); exit 0 }
    [Console]::Error.WriteLine('Codex SafeDelete: ' + $_.Exception.Message)
    exit 1
}
