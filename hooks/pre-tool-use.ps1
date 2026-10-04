# Codex sends the PreToolUse event as JSON on stdin.
$ErrorActionPreference = 'Stop'
try {
    try {
        . (Join-Path $PSScriptRoot '..\src\Protection.ps1')
        $enabled = Read-SafeDeleteProtectionEnabled -InstallDir (Split-Path -Parent $PSScriptRoot)
    } catch {
        # Windows shell wrapping can normalize exit 2 to 1; deny explicitly.
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        [Console]::Error.WriteLine('Codex SafeDelete: protection state could not be verified. ' + $_.Exception.Message)
        [Console]::Out.WriteLine('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Codex SafeDelete: protection state could not be verified. Run safedelete status."}}')
        exit 0
    }
    if (-not $enabled) {
        [Console]::Out.WriteLine('{}')
        exit 0
    }
    & (Join-Path $PSScriptRoot '..\src\safedelete.ps1') -Action hook
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine('Codex SafeDelete: hook failed; original command denied.')
        exit 2
    }
    exit 0
} catch {
    # Codex treats exit 2 as blocking. Other hook errors may fail open.
    [Console]::Error.WriteLine('Codex SafeDelete: hook failed; original command denied. ' + $_.Exception.Message)
    exit 2
}
