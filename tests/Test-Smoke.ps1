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
    7. The dashboard's telemetry API (/api/telemetry/...) answers 404: it is switched off.
    8. Signed in at Keycloak (username page, password page, form_post), Tom (no dashboard-viewer role) does not get the dashboard, the
       admin (client role dashboard-viewer) does. The demo password comes from the AppHost user secrets and reaches curl in a file.
    10. Only Traefik reaches the gateway and Keycloak (plan 08 ruling 5): both trust X-Forwarded-* from the pod network, so a curl pod in
       namespace procure that sends X-Forwarded-For: 203.0.113.9 straight to the gateway's or Keycloak's Service is refused (the
       connection times out or is rejected), while the same requests through Traefik answer 200 and the pod still reaches an ordinary
       service (requests-api) directly.
    9. (first) The cluster's published ports (80, 443, the API) listen on 127.0.0.1 / ::1 only (docker bindings and Windows listeners),
       never on the PC's network interfaces (final review I1).
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

function Invoke-DashboardSignIn {
    # A fresh browser (own cookie jar) opens the dashboard and signs in at Keycloak as $User. Keycloak's login is two pages (username, then
    # password) and answers with an auto-submitting form_post page to the dashboard's callback. Returns @{ Status; Url; Body; Error } of
    # the dashboard page it ends on.
    param([Parameter(Mandatory)] [string] $User, [Parameter(Mandatory)] [string] $PasswordFile)
    $userJar = Join-Path $work "dashboard-$($User.Split('@')[0]).txt"
    $page = Join-Path $work 'dashboard-page.html'
    function Step([string[]] $curlArgs) {
        $written = & $curl -sS --max-time 20 --ssl-no-revoke --cacert $caFile -c $userJar -b $userJar -o $page -w '%{http_code} %{url_effective}' @curlArgs 2>&1
        $parts = "$written" -split ' ', 2
        [pscustomobject]@{ Status = [int]($parts[0] -replace '\D', '0'); Url = if ($parts.Count -gt 1) { $parts[1] } else { '' }; Body = if (Test-Path $page) { Get-Content -Raw $page } else { '' } }
    }
    function Get-FormAction([string] $html) {
        $m = [regex]::Match($html, '<form[^>]*\saction="([^"]+)"', 'IgnoreCase')
        if ($m.Success) { [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) } else { $null }
    }
    $r = Step @('-L', '--max-redirs', '10', "https://$DashboardHost/")
    $action = Get-FormAction $r.Body
    if ($r.Status -ne 200 -or -not $r.Url.StartsWith("https://$KeycloakHost/") -or -not $action) {
        return [pscustomobject]@{ Error = "no Keycloak login page ($($r.Status) at $($r.Url))" }
    }
    $r = Step @('-X', 'POST', '--data-urlencode', "username=$User", $action)
    $action = Get-FormAction $r.Body
    if ($r.Status -ne 200 -or -not $action -or $r.Body -notmatch 'name="password"') {
        return [pscustomobject]@{ Error = "no password page after the username ($($r.Status))" }
    }
    $r = Step @('-X', 'POST', '--data-urlencode', "username=$User", '--data-urlencode', "password@$PasswordFile", $action)
    $action = Get-FormAction $r.Body
    $fields = @([regex]::Matches($r.Body, '<input[^>]*\sname="([^"]+)"[^>]*\svalue="([^"]*)"', 'IgnoreCase') |
        ForEach-Object { '--data-urlencode'; "$($_.Groups[1].Value)=$([Net.WebUtility]::HtmlDecode($_.Groups[2].Value))" })
    if (-not $action -or -not $action.StartsWith("https://$DashboardHost/") -or $r.Body -notmatch '(?i)name="code"') {
        return [pscustomobject]@{ Error = "Keycloak did not hand back an authorization code (wrong password?) ($($r.Status) at $($r.Url))" }
    }
    # The callback sets the dashboard's cookie and redirects to where the visit started; follow it.
    $r = Step (@('-L', '--max-redirs', '10', '-X', 'POST') + $fields + @($action))
    $r = Step @('-L', '--max-redirs', '10', "https://$DashboardHost/")
    [pscustomobject]@{ Status = $r.Status; Url = $r.Url; Body = $r.Body; Error = $null }
}

try {
    # --- 9. Loopback only (first: the checks below go through these ports) ------------------------------------------------------
    $exposure = @(Get-ClusterPortExposure)
    if ($exposure) { foreach ($line in $exposure) { Fail "published port not on loopback only: $line" } }
    else { Pass "ports $($PublishedPorts -join ', ') listen on 127.0.0.1 / ::1 only (docker bindings and Windows listeners)" }

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

    # --- 7. The dashboard's telemetry API is off ---------------------------------------------------------------------------------------
    # Dashboard__Api__Disabled: the API (/api/telemetry/..., its own auth mode) must not answer at all, signed in or not.
    foreach ($path in '/api/telemetry/logs', '/api/telemetry/traces') {
        $r = Invoke-Curl "https://$DashboardHost$path"
        if ($r.Status -eq 404) { Pass "https://$DashboardHost$path answers 404 (dashboard API off)" }
        else { Fail "https://$DashboardHost$path answered $($r.Status), expected 404 (the dashboard API must be off)" }
    }

    # --- 8. Only dashboard-viewer gets in --------------------------------------------------------------------------------------------
    # Signs in at Keycloak as a browser does (username page, password page, form_post back to the dashboard) and opens the dashboard: Tom
    # (no dashboard-viewer role) must not see it, the admin (the only demo user with it) must. The password goes to curl from a file in the
    # current-user-only work folder (--data-urlencode password@file), never on a command line.
    $passwordFile = Join-Path $work 'password.txt'
    $demoPassword = (Read-UserSecrets)['Parameters:keycloak-demo-password']
    if (-not $demoPassword) { Fail 'AppHost user secret Parameters:keycloak-demo-password is missing' }
    else {
        [IO.File]::WriteAllText($passwordFile, $demoPassword)
        $demoPassword = $null
        foreach ($case in @(@{ User = 'tom@acme.test'; Allowed = $false }, @{ User = 'admin@acme.test'; Allowed = $true })) {
            $result = Invoke-DashboardSignIn -User $case.User -PasswordFile $passwordFile
            $seesDashboard = $result.Status -eq 200 -and $result.Url.StartsWith("https://$DashboardHost/") -and $result.Body.Contains('name="aspire-version"')
            if ($result.Error) { Fail "dashboard sign-in as $($case.User): $($result.Error)" }
            elseif ($case.Allowed -and $seesDashboard) { Pass "$($case.User) (dashboard-viewer) signs in and sees the dashboard" }
            elseif (-not $case.Allowed -and -not $seesDashboard -and $result.Status -in 401, 403, 404 -and $result.Url.StartsWith("https://$DashboardHost/")) {
                Pass "$($case.User) (no dashboard-viewer) signs in at Keycloak but the dashboard refuses: $($result.Status) at $($result.Url)"
            } else {
                Fail "dashboard sign-in as $($case.User): ended with $($result.Status) at $($result.Url) (expected $(if ($case.Allowed) { 'the dashboard' } else { 'a refusal' }))"
            }
        }
        Remove-Item $passwordFile -Force
    }

    # --- 10. Only Traefik reaches the gateway and Keycloak -----------------------------------------------------------------------------
    # One throwaway curl pod (no label any NetworkPolicy allows by name) runs every probe; it trusts the local CA from ConfigMap procure-ca.
    # The control (requests-api, allowed for every pod of the namespace) is retried first: the policy controller adds a new pod's address
    # to the allowed set a moment after it starts. Then each probe sends the spoofed header; curl exit 28 = timed out, 7 = rejected.
    $probeScript = @'
for i in 1 2 3 4 5 6 7 8 9 10; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://requests-api:8080/health/ready); e=$?
  [ "$c" = 200 ] && break; sleep 2
done
echo "PROBE control $c $e"
xff='X-Forwarded-For: 203.0.113.9'
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "$xff" http://gateway:8080/health/ready); echo "PROBE direct-gateway $c $?"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "$xff" http://keycloak:8080/realms/procure/.well-known/openid-configuration); echo "PROBE direct-keycloak $c $?"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert /ca/ca.crt -H "$xff" --connect-to procure.localtest.me:443:traefik.kube-system.svc.cluster.local:443 https://procure.localtest.me/health/ready); echo "PROBE traefik-gateway $c $?"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert /ca/ca.crt -H "$xff" https://auth.procure.localtest.me/realms/procure/.well-known/openid-configuration); echo "PROBE traefik-keycloak $c $?"
'@
    $probePod = 'smoke-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $overrides = [ordered]@{
        apiVersion = 'v1'
        spec       = [ordered]@{
            automountServiceAccountToken = $false
            securityContext              = [ordered]@{ runAsNonRoot = $true; runAsUser = 100; runAsGroup = 101; seccompProfile = @{ type = 'RuntimeDefault' } }
            containers                   = @([ordered]@{
                    name            = $probePod
                    image           = 'docker.io/curlimages/curl:8.23.0'
                    command         = @('sh', '-c', ($probeScript -replace "`r", ''))
                    resources       = [ordered]@{ limits = [ordered]@{ memory = '64Mi'; cpu = '200m' }; requests = [ordered]@{ memory = '16Mi'; cpu = '10m' } }
                    securityContext = [ordered]@{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
                    volumeMounts    = @([ordered]@{ name = 'ca'; mountPath = '/ca'; readOnly = $true })
                })
            volumes                      = @([ordered]@{ name = 'ca'; configMap = [ordered]@{ name = 'procure-ca' } })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $out = & kubectl --context $KubeContext -n procure run $probePod --image=docker.io/curlimages/curl:8.23.0 --restart=Never --rm -i --quiet `
        --labels='app.kubernetes.io/name=smoke-probe' --overrides=$overrides --pod-running-timeout=2m 2>&1 | ForEach-Object { "$_" }
    & kubectl --context $KubeContext -n procure delete pod $probePod --ignore-not-found --wait=false 2>&1 | Out-Null
    $probes = @{}
    foreach ($line in $out) { if ($line -match '^PROBE (\S+) (\d{3}) (\d+)$') { $probes[$Matches[1]] = @{ Code = $Matches[2]; Exit = [int] $Matches[3] } } }
    function Show([string] $name) { if ($probes.ContainsKey($name)) { "HTTP $($probes[$name].Code), curl exit $($probes[$name].Exit)" } else { 'no result' } }
    if (-not $probes.ContainsKey('control') -or $probes['control'].Code -ne '200') {
        Fail "probe pod could not reach requests-api directly ($(Show 'control')); output: $(($out | Select-Object -Last 5) -join ' | ')"
    } else {
        Pass 'a pod in procure reaches an ordinary service (requests-api) directly'
        foreach ($name in 'direct-gateway', 'direct-keycloak') {
            $p = $probes[$name]
            if ($p -and $p.Code -eq '000' -and $p.Exit -in 7, 28) { Pass "$name with X-Forwarded-For: 203.0.113.9 is refused ($(if ($p.Exit -eq 28) { 'timed out' } else { 'rejected' }))" }
            else { Fail "$name with X-Forwarded-For: 203.0.113.9 was not refused ($(Show $name)): only Traefik may connect" }
        }
        foreach ($name in 'traefik-gateway', 'traefik-keycloak') {
            $p = $probes[$name]
            if ($p -and $p.Code -eq '200') { Pass "$name (the same request through Traefik) answers 200" } else { Fail "$name answered $(Show $name), expected 200" }
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
