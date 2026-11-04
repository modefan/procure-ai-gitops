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
    TLS is verified against the local CA (%USERPROFILE%\.procure-ai\local-ca\ca.crt) with curl (not .NET: ESET on this PC intercepts TLS
    from pwsh). The admin key goes to curl in a header file that only the current user can read, never on a command line; nothing
    secret is printed. Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [string] $AppHost = 'procure.localtest.me',
    [string] $KeycloakHost = 'auth.procure.localtest.me',
    [string] $Tenant = 'acme'
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

# Git for Windows' curl uses OpenSSL and honours --cacert like on Linux; the Windows curl.exe (Schannel) is the fallback.
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
    $status = & $curl -sS --max-time 20 --cacert $caFile -o $bodyFile -w '%{http_code}' -b $jar -c $jar @Extra $Url 2>&1
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
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) smoke check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nSmoke checks passed." -ForegroundColor Green
exit 0
