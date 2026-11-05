#Requires -Version 7.4
<#
.SYNOPSIS
    Smoke check of a running procure-ai through the ingress, as a browser and as Claude's admin key reach it.
.DESCRIPTION
    1. The gateway's /health/ready answers 200 at https://procure.localtest.me.
    2. Keycloak's discovery document answers at https://auth.procure.localtest.me with the issuer the tokens carry.
    3. Demo login as Tom (what the welcome page does: GET /bff/demo-login/users hands out the XSRF token, POST /bff/demo-login with it)
       returns 204 and the BFF session cookie __Host-procure, and /bff/user then answers 200.
    4. GET /api/v1/requests with the admin key (user env var DEMO_ADMIN_API_KEY) and X-Tenant-Id: acme returns seeded rows.
    5. The Argo CD Application `observability` is Synced and Healthy (collector DaemonSet, Aspire dashboard).
    6. The dashboard's root at https://dashboard.procure.localtest.me redirects to Keycloak's authorization endpoint for client
       aspire-dashboard, after Keycloak accepted the pushed authorization request (OIDC on, forwarded headers trusted, redirect URI and
       scopes valid).
    TLS is verified against the local CA (%USERPROFILE%\.procure-ai\local-ca\ca.crt) with curl (not .NET: ESET on this PC intercepts TLS
    from pwsh). The admin key goes to curl in a header file that only the current user can read, never on a command line; nothing
    secret is printed. Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [string] $AppHost = 'procure.localtest.me',
    [string] $KeycloakHost = 'auth.procure.localtest.me',
    [string] $DashboardHost = 'dashboard.procure.localtest.me',
    [string] $Tenant = 'acme'
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

# Git for Windows' curl, else Windows' curl.exe. Both use Schannel here: --cacert pins the local CA, --ssl-no-revoke because it has no CRL.
$curl = @('C:\Program Files\Git\mingw64\bin\curl.exe', "$env:SystemRoot\System32\curl.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$caFile = Join-Path $LocalCaDir 'ca.crt'
if (-not (Test-Path $caFile)) { throw "Local CA $caFile not found (bootstrap/new-local-ca.ps1)." }

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Set-CurrentUserOnlyAcl $work
$jar = Join-Path $work 'cookies.txt'

function Invoke-Curl {
    # Returns @{ Status; Body }. Extra curl arguments after the URL.
    param([Parameter(Mandatory)] [string] $Url, [string[]] $Extra = @())
    $bodyFile = Join-Path $work 'body.txt'
    $status = & $curl -sS --max-time 20 --ssl-no-revoke --cacert $caFile -o $bodyFile -w '%{http_code}' -b $jar -c $jar @Extra $Url 2>&1
    $code = if ("$status" -match '(\d{3})$') { [int] $Matches[1] } else { 0 }
    $body = if (Test-Path $bodyFile) { Get-Content -Raw $bodyFile } else { '' }
    if ($code -eq 0) { $body = "$status" }
    [pscustomobject]@{ Status = $code; Body = $body }
}

function Get-JarCookie([string] $name) {
    # Netscape cookie file: domain, flag, path, secure, expiry, name, value (HttpOnly cookies have a #HttpOnly_ prefix).
    if (-not (Test-Path $jar)) { return $null }
    foreach ($line in Get-Content $jar) {
        $fields = $line -split "`t"
        if ($fields.Count -ge 7 -and $fields[5] -eq $name) { return $fields[6] }
    }
    $null
}

try {
    # --- 1. Gateway readiness through Traefik ---------------------------------------------------------------------------------------
    $r = Invoke-Curl "https://$AppHost/health/ready"
    if ($r.Status -eq 200) { Pass "https://$AppHost/health/ready answers 200" }
    else { Fail "https://$AppHost/health/ready answered $($r.Status): $($r.Body.Substring(0, [Math]::Min(300, $r.Body.Length)))" }

    # --- 2. Keycloak discovery ------------------------------------------------------------------------------------------------------
    $issuer = "https://$KeycloakHost/realms/procure"
    $r = Invoke-Curl "$issuer/.well-known/openid-configuration"
    if ($r.Status -ne 200) { Fail "Keycloak discovery answered $($r.Status)" }
    else {
        $doc = $r.Body | ConvertFrom-Json
        if ($doc.issuer -eq $issuer) { Pass "Keycloak discovery: issuer $issuer" } else { Fail "Keycloak issuer is '$($doc.issuer)', expected $issuer" }
    }

    # --- 3. Demo login as Tom -------------------------------------------------------------------------------------------------------
    $r = Invoke-Curl "https://$AppHost/bff/demo-login/users"
    $xsrf = Get-JarCookie 'XSRF-TOKEN'
    if ($r.Status -ne 200 -or -not $xsrf) { Fail "GET /bff/demo-login/users answered $($r.Status) (XSRF token: $([bool]$xsrf))" }
    else {
        $r = Invoke-Curl "https://$AppHost/bff/demo-login" @('-X', 'POST', '-H', 'Content-Type: application/json',
            '-H', "X-XSRF-TOKEN: $([Uri]::UnescapeDataString($xsrf))", '--data', '{"user":"tom"}')
        $session = Get-JarCookie '__Host-procure'
        if ($r.Status -eq 204 -and $session) { Pass 'demo login as Tom: 204 and the BFF cookie __Host-procure' }
        else { Fail "demo login as Tom answered $($r.Status), session cookie: $([bool]$session) $($r.Body.Substring(0, [Math]::Min(300, $r.Body.Length)))" }
        $r = Invoke-Curl "https://$AppHost/bff/user"
        if ($r.Status -eq 200) { Pass "/bff/user answers 200 for Tom's session" } else { Fail "/bff/user answered $($r.Status) after the demo login" }
    }

    # --- 4. Seeded requests with the admin key -------------------------------------------------------------------------------------
    $key = [Environment]::GetEnvironmentVariable('DEMO_ADMIN_API_KEY', 'Process')
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable('DEMO_ADMIN_API_KEY', 'User') }
    if (-not $key) { Fail 'user env var DEMO_ADMIN_API_KEY is not set' }
    else {
        $headers = Join-Path $work 'headers.txt'
        Set-Content -Path $headers -Value @("X-Api-Key: $key", "X-Tenant-Id: $Tenant") -NoNewline:$false
        $r = Invoke-Curl "https://$AppHost/api/v1/requests?pageSize=5" @('-H', "@$headers")
        Remove-Item $headers -Force
        if ($r.Status -ne 200) { Fail "GET /api/v1/requests (admin key, tenant $Tenant) answered $($r.Status)" }
        else {
            $page = $r.Body | ConvertFrom-Json
            $count = @($page.items).Count
            if ($count -gt 0) { Pass "GET /api/v1/requests (admin key, tenant $Tenant): $count seeded rows on the first page (total $($page.total))" }
            else { Fail "GET /api/v1/requests (admin key, tenant $Tenant) returned no rows (is the demo seed done?)" }
        }
    }

    # --- 5. The observability Application ------------------------------------------------------------------------------------------
    $appJson = & kubectl --context $KubeContext -n argocd get application observability -o json 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Argo CD Application observability not found: $appJson" }
    else {
        $app = ($appJson -join "`n") | ConvertFrom-Json
        $sync = $app.status.sync.status; $health = $app.status.health.status
        if ($sync -eq 'Synced' -and $health -eq 'Healthy') { Pass 'Argo CD Application observability is Synced and Healthy' }
        else { Fail "Argo CD Application observability is $sync / $health" }
    }

    # --- 6. The dashboard signs in with Keycloak -----------------------------------------------------------------------------------
    # The dashboard first redirects within its own host (/ -> /structuredlogs), then challenges with OIDC. It pushes the authorization
    # request to Keycloak first (PAR), so the browser's Location carries request_uri instead of redirect_uri: Keycloak only issues a
    # request_uri after it accepted the client, its secret, the redirect URI https://<dashboard>/ and the scopes (it answers 400 otherwise,
    # and the dashboard 500).
    $url = "https://$DashboardHost/"; $location = $null; $status = 0
    foreach ($hop in 1..3) {
        $headerFile = Join-Path $work "dashboard-headers-$hop.txt"
        $r = Invoke-Curl $url @('-D', $headerFile)
        $status = $r.Status
        $location = (Get-Content $headerFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^location:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -Last 1)
        if ($status -ne 302 -or -not $location) { break }
        if ($location.StartsWith('/')) { $location = "https://$DashboardHost$location" }
        if (-not $location.StartsWith("https://$DashboardHost/")) { break }
        $url = $location
    }
    $authorize = "https://$KeycloakHost/realms/procure/protocol/openid-connect/auth?"
    $redirect = "redirect_uri=$([Uri]::EscapeDataString("https://$DashboardHost/"))"
    if ($status -eq 302 -and $location -and $location.StartsWith($authorize) -and $location.Contains('client_id=aspire-dashboard') -and
        ($location.Contains('request_uri=') -or $location.Contains($redirect))) {
        Pass "https://$DashboardHost/ redirects to Keycloak's sign-in for client aspire-dashboard (authorization request accepted)"
    } else {
        $shown = if ($location) { $location.Substring(0, [Math]::Min(300, $location.Length)) } else { '(no Location header)' }
        Fail "https://$DashboardHost/ ended with $status at $url, Location: $shown"
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) smoke check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nSmoke checks passed." -ForegroundColor Green
exit 0
