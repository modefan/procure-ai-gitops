#Requires -Version 7.4
<#
.SYNOPSIS
    Checks that the Aspire dashboard really works for an operator (plan 08b; CLAUDE.md "Operating the live system"): signed in with a
    real browser, Structured logs and Traces show rows, with fresh rows from the app services.
.DESCRIPTION
    Green smoke checks were not enough: on 2026-11-08 the hosted dashboard had shown nothing for days (every Blazor circuit refused with
    403, finding 1) and, once that was fixed, its tables often stayed blank after a full page load (finding 2). This check:

    1. Makes fresh telemetry: GET /api/v1/requests through the gateway with the admin key (user env var DEMO_ADMIN_API_KEY, or
       DEMO_ADMIN_API_KEY_HOSTED for hosted): a trace through the gateway and requests-api, and requests-api's log line "Admin API key
       call as claude-admin ..." from the last minute. (The gateway writes no log line for a normal request.)
    2. Blazor's WebSocket and its Origin check, with curl (no sign-in needed; the check runs before the circuit):
       - the dashboard's own Origin is accepted on /_blazor (404 for an unknown circuit id, not 403);
       - the same on /_Blazor: Traefik matches paths case-sensitively and ASP.NET does not, so this reaches the dashboard through its
         main Ingress (the one with the X-Forwarded-Proto middleware) even while a longer /_blazor Ingress exists;
       - a foreign Origin (https://evil.example.com) and the dashboard's host with http:// get 403 on both.
    3. In Microsoft Edge (tests/dashboard/check-dashboard.mjs, playwright-core): signs in at Keycloak as the demo admin (client role
       dashboard-viewer; the password from the user secrets), opens Structured logs and Traces -Loads times each as full page loads and
       needs rows within 20 s every time, then opens the resource pages (/structuredlogs/resource/<name> for each -LogServices,
       /traces/resource/<name> for each -TraceServices) and needs the newest row to be at most -MaxAgeMinutes old, and the newest trace
       to start at -TraceRoot (the gateway: the request came in through it). /traces/resource/gateway itself is not used: on dashboard
       13.6.2 it stopped listing new gateway-rooted traces that the requests-api page lists (seen 2026-11-08).

    -NoNudge blocks the workaround script (/_procure/virtualize-nudge.js, procure-ai deploy/charts/procure-observability): run it after an
    Aspire dashboard upgrade; when every load still shows rows, the workaround can go (dashboard.proxy.enabled: false).

    Needs Node.js and Microsoft Edge; the first run installs playwright-core (pinned, tests/dashboard/package-lock.json) into
    tests/dashboard/node_modules. Nothing secret is printed. Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'hosted')]
    [string] $Environment = 'local',
    [string[]] $LogServices = @('requests-api'),
    [string[]] $TraceServices = @('requests-api'),
    [string] $TraceRoot = 'gateway',
    [int] $MaxAgeMinutes = 10,
    [int] $Loads = 3,
    [string] $Tenant = 'acme',
    [switch] $NoNudge,
    [switch] $Headed
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
Select-ProcureCluster $Environment
$hosted = $Environment -eq 'hosted'
$baseDomain = if ($hosted) { $HostedDomain } else { 'procure.localtest.me' }
$appHost = if ($hosted) { "procure.$HostedDomain" } else { 'procure.localtest.me' }
$dashboardHost = "dashboard.$baseDomain"
$adminKeyVar = if ($hosted) { 'DEMO_ADMIN_API_KEY_HOSTED' } else { 'DEMO_ADMIN_API_KEY' }
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

# curl as in Test-Smoke.ps1 (not .NET: ESET on this PC intercepts TLS from pwsh). Local: the local CA; hosted: Windows' trusted roots.
$curl = @('C:\Program Files\Git\mingw64\bin\curl.exe', "$env:SystemRoot\System32\curl.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$tlsArgs = @('--ssl-no-revoke')
if (-not $hosted) {
    $caFile = Join-Path $LocalCaDir 'ca.crt'
    if (-not (Test-Path $caFile)) { throw "Local CA $caFile not found (bootstrap/new-local-ca.ps1)." }
    $tlsArgs += @('--cacert', $caFile)
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-dashboard-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Set-CurrentUserOnlyAcl $work

try {
    # --- 1. Fresh telemetry from the gateway and requests-api ---------------------------------------------------------------------
    $key = [Environment]::GetEnvironmentVariable($adminKeyVar, 'Process')
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable($adminKeyVar, 'User') }
    if (-not $key) { Fail "user env var $adminKeyVar is not set (needed to make fresh telemetry)" }
    else {
        $headers = Join-Path $work 'headers.txt'
        Set-Content -Path $headers -Value @("X-Api-Key: $key", "X-Tenant-Id: $Tenant")
        $key = $null
        $status = & $curl -sS --max-time 20 @tlsArgs -o (Join-Path $work 'body.txt') -w '%{http_code}' -H "@$headers" "https://$appHost/api/v1/requests?pageSize=1" 2>&1
        Remove-Item $headers -Force
        if ("$status" -eq '200') { Pass "GET https://$appHost/api/v1/requests (admin key, tenant $Tenant) answered 200: fresh telemetry made" }
        else { Fail "GET https://$appHost/api/v1/requests (admin key) answered $status" }
    }

    # --- 2. Blazor's WebSocket Origin check -----------------------------------------------------------------------------------------
    function Get-UpgradeStatus([string] $Path, [string] $Origin) {
        $code = & $curl -sS --http1.1 --max-time 15 @tlsArgs -o (Join-Path $work 'upgrade.txt') -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' `
            -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: $Origin" "https://$dashboardHost$Path" 2>&1
        "$code"
    }
    foreach ($path in '/_blazor', '/_Blazor') {
        $own = Get-UpgradeStatus "$path`?id=procure-dashboard-check" "https://$dashboardHost"
        if ($own -ne '403' -and $own -match '^\d{3}$' -and $own -ne '000') { Pass "$path WebSocket upgrade from the dashboard's own Origin passes the Origin check ($own for an unknown circuit)" }
        else { Fail "$path WebSocket upgrade from https://$dashboardHost answered $own (403: the Origin check refuses the dashboard itself, finding 1)" }
        foreach ($origin in 'https://evil.example.com', "http://$dashboardHost") {
            $foreign = Get-UpgradeStatus "$path`?id=procure-dashboard-check" $origin
            if ($foreign -eq '403') { Pass "$path WebSocket upgrade from Origin $origin is refused (403)" }
            else { Fail "$path WebSocket upgrade from Origin $origin answered $foreign, expected 403" }
        }
    }

    # --- 3. The browser ---------------------------------------------------------------------------------------------------------------
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js (node) not found.' }
    $dir = Join-Path $PSScriptRoot 'dashboard'
    if (-not (Test-Path (Join-Path $dir 'node_modules/playwright-core'))) {
        Write-Host 'Installing playwright-core (tests/dashboard/package-lock.json) ...'
        Push-Location $dir
        try { & npm ci --no-audit --no-fund --loglevel=error | Out-Host; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed in tests/dashboard.' } } finally { Pop-Location }
    }
    $password = (Read-UserSecrets)['Parameters:keycloak-demo-password']
    if (-not $password) { Fail "user secret Parameters:keycloak-demo-password is missing in $UserSecretsId" }
    else {
        $env:DASHBOARD_URL = "https://$dashboardHost"
        $env:DASHBOARD_USER = 'admin@acme.test'
        $env:DASHBOARD_PASSWORD = $password
        $password = $null
        $env:DASHBOARD_LOG_SERVICES = $LogServices -join ','
        $env:DASHBOARD_TRACE_SERVICES = $TraceServices -join ','
        $env:DASHBOARD_TRACE_ROOT = $TraceRoot
        $env:DASHBOARD_MAX_AGE_MIN = "$MaxAgeMinutes"
        $env:DASHBOARD_LOADS = "$Loads"
        $env:DASHBOARD_NO_NUDGE = if ($NoNudge) { '1' } else { '' }
        $env:DASHBOARD_IGNORE_TLS = if ($hosted) { '' } else { '1' }
        $env:DASHBOARD_HEADED = if ($Headed) { '1' } else { '' }
        try {
            Push-Location $dir
            $lines = @(& node (Join-Path $dir 'check-dashboard.mjs') 2>&1 | ForEach-Object { "$_" })
        } finally {
            Pop-Location
            foreach ($name in 'DASHBOARD_URL', 'DASHBOARD_USER', 'DASHBOARD_PASSWORD', 'DASHBOARD_LOG_SERVICES', 'DASHBOARD_TRACE_SERVICES', 'DASHBOARD_TRACE_ROOT', 'DASHBOARD_MAX_AGE_MIN', 'DASHBOARD_LOADS',
                              'DASHBOARD_NO_NUDGE', 'DASHBOARD_IGNORE_TLS', 'DASHBOARD_HEADED') {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        foreach ($line in $lines) {
            if ($line -match '^ok:\s+(.*)$') { Pass $Matches[1] }
            elseif ($line -match '^FAIL:\s+(.*)$') { Fail $Matches[1] }
            elseif ($line.Trim()) { Write-Host "  $line" }
        }
        if (-not ($lines | Where-Object { $_ -match '^(ok|FAIL):' })) { Fail 'the browser check printed no result' }
    }
}
finally {
    if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) dashboard check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'The dashboard works: signed in, tables load, fresh rows from every service, Origin check intact.' -ForegroundColor Green
