#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the Application health check of argocd/values.yaml (Lua) against the cases in tests/health/application-health-cases.lua.
.DESCRIPTION
    Needs a Lua interpreter (`lua`; winget install DEVCOM.Lua). Argo CD runs the script in gopher-lua (Lua 5.1); the script uses only
    what both have. Exit code 1 on any failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lua = (Get-Command lua -ErrorAction SilentlyContinue).Source
if (-not $lua) { $lua = @("$env:LOCALAPPDATA\Programs\Lua\bin\lua.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if (-not $lua) { throw 'lua not found (winget install DEVCOM.Lua).' }

# The block scalar under resource.customizations.health.argoproj.io_Application: every following line indented by 6 spaces (or empty).
$lines = Get-Content (Join-Path $repoRoot 'argocd/values.yaml')
$start = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^\s+resource\.customizations\.health\.argoproj\.io_Application:\s*\|\s*$' })
if ($start -lt 0) { throw 'Application health check not found in argocd/values.yaml.' }
$body = foreach ($line in $lines[($start + 1)..($lines.Count - 1)]) {
    if ($line -match '^      ' ) { $line.Substring(6) } elseif ($line -match '^\s*$') { '' } else { break }
}
$scriptFile = Join-Path ([IO.Path]::GetTempPath()) "application-health-$PID.lua"
Set-Content -Path $scriptFile -Value $body -Encoding utf8NoBOM
try {
    & $lua (Join-Path $PSScriptRoot 'health/run.lua') $scriptFile (Join-Path $PSScriptRoot 'health/application-health-cases.lua')
    $code = $LASTEXITCODE
} finally {
    Remove-Item $scriptFile -ErrorAction SilentlyContinue
}
exit $code
