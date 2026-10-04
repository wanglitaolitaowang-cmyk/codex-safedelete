$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$project = Split-Path -Parent $PSScriptRoot
$run = Join-Path $project ('tests\.work\codepage-compatibility-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$fixture = Join-Path $run ('project with spaces ' + [char]0x6D4B + [char]0x8BD5)
$installDir = Join-Path $fixture ('installed with spaces ' + [char]0x5B89 + [char]0x88C5)
$codexHome = Join-Path $fixture 'isolated-codex-home'
$null = [IO.Directory]::CreateDirectory($fixture)
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object Text.UTF8Encoding($false)
$originalEncoding = [Console]::OutputEncoding
$results = New-Object 'System.Collections.Generic.List[object]'
$evidence = New-Object 'System.Collections.Generic.List[object]'
$installed = $false
function Quote-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    $value = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $value = [regex]::Replace($value, '(\\+)$', '$1$1')
    return '"' + $value + '"'
}
function Invoke-Native([string]$Program, [string]$Arguments, [string]$Directory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Program; $start.Arguments = $Arguments; $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $false; $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8; $start.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Compatibility process timed out.' }
        $result = [pscustomobject]@{ exit=$process.ExitCode; stdout=$stdoutTask.GetAwaiter().GetResult(); stderr=$stderrTask.GetAwaiter().GetResult() }
        $evidence.Add($result)
        return $result
    } finally { $process.Dispose() }
}
try {
    $installArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $project 'install.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate')
    $setup = Invoke-Native $shell (($installArgs | ForEach-Object { Quote-Argument $_ }) -join ' ') $fixture
    if ($setup.exit -ne 0) { throw 'Isolated installation failed; see evidence.' }
    $installed = $true
    $shim = Join-Path $installDir 'safedelete.cmd'
    $bytes = [byte[]](0..255)
    foreach ($page in @(936,65001)) {
        $name = ([char]0x6587).ToString() + ([char]0x4EF6) + " with space's " + [char]::ConvertFromUtf32(0x1F4C1) + '-' + $page + '.bin'
        $file = Join-Path $fixture $name
        [IO.File]::WriteAllBytes($file,$bytes)
        $command = '/d /c chcp ' + $page + ' >nul && echo SAFEDELETE_CODEPAGE=' + $page + ' && call "' + $shim + '" delete "' + $name + '" && chcp ' + $page + ' >nul && echo SAFEDELETE_CODEPAGE=' + $page + ' && call "' + $shim + '" undo'
        $result = Invoke-Native (Join-Path $env:SystemRoot 'System32\cmd.exe') $command $fixture
        $markers = [regex]::Matches($result.stdout, ('(?m)^SAFEDELETE_CODEPAGE=' + $page + '\s*$')).Count
        $sameBytes = [IO.File]::Exists($file) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($bytes)
        $passed = $result.exit -eq 0 -and $markers -eq 2 -and $sameBytes
        $results.Add([pscustomobject]@{ codepage=$page; result=$(if($passed){'PASS'}else{'FAIL'}); exit=$result.exit; verified_codepage_markers=$markers; restored_bytes_identical=$sameBytes })
    }
} finally {
    if ($installed) {
        $uninstallArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $project 'uninstall.ps1'),'-CodexHome',$codexHome,'-InstallDir',$installDir,'-NoPathUpdate')
        $cleanup = Invoke-Native $shell (($uninstallArgs | ForEach-Object { Quote-Argument $_ }) -join ' ') $fixture
        if ($cleanup.exit -ne 0) { throw 'Isolated cleanup failed; see evidence.' }
    }
    [Console]::OutputEncoding = $originalEncoding
    $failed = @($results | Where-Object result -eq FAIL).Count
    $report = [pscustomobject]@{ result=$(if($results.Count -eq 2 -and $failed -eq 0){'PASS'}else{'FAIL'}); total=$results.Count; passed=($results.Count-$failed); failed=$failed; cases=@($results.ToArray()); evidence=@($evidence.ToArray()); fixture=$fixture; isolated_installation_removed=(-not [IO.Directory]::Exists($installDir)) }
    $reportPath = Join-Path $run 'report.json'
    [IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 5),$utf8)
    [pscustomobject]@{result=$report.result;total=$report.total;passed=$report.passed;failed=$report.failed;report=$reportPath}|ConvertTo-Json -Compress
}
if ($report.result -ne 'PASS') { exit 1 }
