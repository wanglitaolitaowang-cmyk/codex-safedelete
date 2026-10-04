[CmdletBinding()]
param([string]$ArtifactRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$source = Split-Path -Parent $PSScriptRoot
. (Join-Path $source 'src\InstallState.ps1')
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path $PSScriptRoot '.work' }
$runRoot = Join-Path $ArtifactRoot ('runtime-preflight-' + $PSVersionTable.PSVersion.Major + '-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($runRoot)
$cases = @(
    @{name='Windows 7 SP1';ps='5.1';os='6.1.7601';platform=[PlatformID]::Win32NT;allowed=$false;reason='Windows 7'},
    @{name='Windows 8.1';ps='5.1';os='6.3.9600';platform=[PlatformID]::Win32NT;allowed=$false;reason='not supported'},
    @{name='Windows 10 before 1809';ps='5.1';os='10.0.14393';platform=[PlatformID]::Win32NT;allowed=$false;reason='1809'},
    @{name='Windows 10 1809';ps='5.1';os='10.0.17763';platform=[PlatformID]::Win32NT;allowed=$true;reason=''},
    @{name='Windows 11';ps='7.6';os='10.0.22631';platform=[PlatformID]::Win32NT;allowed=$true;reason=''},
    @{name='Windows PowerShell 2';ps='2.0';os='10.0.22631';platform=[PlatformID]::Win32NT;allowed=$false;reason='5.1'},
    @{name='Windows PowerShell 5.0';ps='5.0';os='10.0.22631';platform=[PlatformID]::Win32NT;allowed=$false;reason='5.1'},
    @{name='Unix platform';ps='7.6';os='6.8';platform=[PlatformID]::Unix;allowed=$false;reason='not implemented'}
)
$results = @()
foreach ($case in $cases) {
    $allowed = $true
    $reason = ''
    try { Assert-SafeDeleteSupportedInstallRuntime -PowerShellVersion $case.ps -Platform $case.platform -WindowsVersion $case.os }
    catch { $allowed = $false; $reason = $_.Exception.Message }
    $passed = $allowed -eq $case.allowed -and ($case.allowed -or $reason.Contains($case.reason))
    $results += [pscustomobject]@{name=$case.name;simulated=$true;passed=$passed;allowed=$allowed;reason=$reason}
}
$reason = ''
try { Assert-SafeDeleteSupportedInstallRuntime }
catch { $reason = $_.Exception.Message }
$results += [pscustomobject]@{name='Actual local runtime';simulated=$false;passed=($reason -eq '');allowed=($reason -eq '');reason=$reason}
$failed = @($results | Where-Object { -not $_.passed }).Count
$report = [pscustomobject]@{shell=$PSVersionTable.PSVersion.ToString();total=$results.Count;passed=($results.Count-$failed);failed=$failed;simulated_cases=$cases.Count;results=$results}
[IO.File]::WriteAllText((Join-Path $runRoot 'report.json'), ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{shell=$report.shell;total=$report.total;passed=$report.passed;failed=$failed;simulated_cases=$report.simulated_cases;evidence=$runRoot}|ConvertTo-Json
if ($failed -gt 0) { exit 1 }
