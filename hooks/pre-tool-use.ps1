# Codex sends the PreToolUse event as JSON on stdin.
$ErrorActionPreference = 'Stop'
try {
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
