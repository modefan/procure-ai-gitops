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
    11. pgaudit shows who ran the DDL (plan 08 ruling 6): since the first run of roles.sql in the logged week (the db-roles Job; its ALTER
       ROLE ... PASSWORD statements mark it; it reruns on every platform sync), every CREATE TABLE in a service database (the migrations'
       and Wolverine's start-up DDL) in the server's weekday logs was run by that service's own role <service>_app, never by the superuser
       postgres, and at least five databases show one. Read in the
       postgres pod as the superuser through Audit's own log tables (auditdb, pgaudit.log_<weekday>).
    12. The realm in Git matches the server (plan 08 ruling 7): the realm file baked into the deployed Keycloak image, its non-secret
       placeholders filled in, against Keycloak's partial export (kcadm in the pod): each of the file's clients' redirect URIs, web
       origins, post-logout redirect URIs, client scopes and client roles, the file's client scopes and their mappers, the realm roles.
       A change made by hand in the admin console shows here until the keycloak-config Job of the next sync puts the file back.
    9. (first) The cluster's published ports (80, 443, the API) listen on 127.0.0.1 / ::1 only (docker bindings and Windows listeners),
       never on the PC's network interfaces (final review I1).
    TLS is verified against the local CA (%USERPROFILE%\.procure-ai\local-ca\ca.crt) with curl (not .NET: ESET on this PC intercepts TLS
    from pwsh). The admin key goes to curl in a header file that only the current user can read, never on a command line; nothing
    secret is printed. Exit code 1 on any failure.

    -Environment hosted (plan 08 Task 12): the hosted VM through the SSH tunnel, the public host names (procure, auth,
    dashboard.daleabels.com), certificates verified against Windows' trusted roots (Let's Encrypt), the admin key from the user env var
    DEMO_ADMIN_API_KEY_HOSTED and the demo password from the hosted user secrets (procure-ai-hosted). Check 9 (loopback) is the local
    cluster's; the hosted surface is tests/Test-PublicSurface.ps1.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'hosted')]
    [string] $Environment = 'local',
    [string] $AppHost,
    [string] $KeycloakHost,
    [string] $DashboardHost,
    [string] $Tenant = 'acme'
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
Select-ProcureCluster $Environment
$hosted = $Environment -eq 'hosted'
$baseDomain = if ($hosted) { $HostedDomain } else { 'procure.localtest.me' }
if (-not $AppHost) { $AppHost = if ($hosted) { "procure.$HostedDomain" } else { 'procure.localtest.me' } }
if (-not $KeycloakHost) { $KeycloakHost = "auth.$baseDomain" }
if (-not $DashboardHost) { $DashboardHost = "dashboard.$baseDomain" }
$adminKeyVar = if ($hosted) { 'DEMO_ADMIN_API_KEY_HOSTED' } else { 'DEMO_ADMIN_API_KEY' }
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

# Git for Windows' curl, else Windows' curl.exe. Both use Schannel here: --cacert pins the local CA, --ssl-no-revoke because it has no CRL.
# Hosted: Let's Encrypt certificates, verified against Windows' trusted roots (no --cacert).
$curl = @('C:\Program Files\Git\mingw64\bin\curl.exe', "$env:SystemRoot\System32\curl.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$tlsArgs = @('--ssl-no-revoke')
if (-not $hosted) {
    $caFile = Join-Path $LocalCaDir 'ca.crt'
    if (-not (Test-Path $caFile)) { throw "Local CA $caFile not found (bootstrap/new-local-ca.ps1)." }
    $tlsArgs += @('--cacert', $caFile)
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Set-CurrentUserOnlyAcl $work
$jar = Join-Path $work 'cookies.txt'

function Invoke-Curl {
    # Returns @{ Status; Body }. Extra curl arguments after the URL.
    param([Parameter(Mandatory)] [string] $Url, [string[]] $Extra = @())
    $bodyFile = Join-Path $work 'body.txt'
    $status = & $curl -sS --max-time 20 @tlsArgs -o $bodyFile -w '%{http_code}' -b $jar -c $jar @Extra $Url 2>&1
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
        $written = & $curl -sS --max-time 20 @tlsArgs -c $userJar -b $userJar -o $page -w '%{http_code} %{url_effective}' @curlArgs 2>&1
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
    # --- 9. Loopback only (first: the checks below go through these ports; the local cluster's, see Test-PublicSurface.ps1 for hosted) ---
    if (-not $hosted) {
        $exposure = @(Get-ClusterPortExposure)
        if ($exposure) { foreach ($line in $exposure) { Fail "published port not on loopback only: $line" } }
        else { Pass "ports $($PublishedPorts -join ', ') listen on 127.0.0.1 / ::1 only (docker bindings and Windows listeners)" }
    }

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
    $key = [Environment]::GetEnvironmentVariable($adminKeyVar, 'Process')
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable($adminKeyVar, 'User') }
    if (-not $key) { Fail "user env var $adminKeyVar is not set" }
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
    $appJson = & kubectl @KubectlArgs -n argocd get application observability -o json 2>&1
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
    if (-not $demoPassword) { Fail "user secret Parameters:keycloak-demo-password is missing in $UserSecretsId" }
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
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 __CA__ -H "$xff" --connect-to __APP__:443:traefik.kube-system.svc.cluster.local:443 https://__APP__/health/ready); echo "PROBE traefik-gateway $c $?"
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 __CA__ -H "$xff" https://__AUTH__/realms/procure/.well-known/openid-configuration); echo "PROBE traefik-keycloak $c $?"
'@
    # Local: the local CA from ConfigMap procure-ca; hosted: Let's Encrypt, which the curl image trusts. The auth host reaches Traefik through
    # the CoreDNS rewrite (bootstrap/coredns-custom.yaml, bootstrap/hosted/coredns-custom.yaml).
    $probeScript = $probeScript.Replace('__CA__', $(if ($hosted) { '' } else { '--cacert /ca/ca.crt' })).Replace('__APP__', $AppHost).Replace('__AUTH__', $KeycloakHost)
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
    $out = & kubectl @KubectlArgs -n procure run $probePod --image=docker.io/curlimages/curl:8.23.0 --restart=Never --rm -i --quiet `
        --labels='app.kubernetes.io/name=smoke-probe' --overrides=$overrides --pod-running-timeout=2m 2>&1 | ForEach-Object { "$_" }
    & kubectl @KubectlArgs -n procure delete pod $probePod --ignore-not-found --wait=false 2>&1 | Out-Null
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

    # --- 11. pgaudit: the services' DDL runs as their own roles ---------------------------------------------------------------------
    # Every role that ran CREATE TABLE in a service database since the EARLIEST run of roles.sql in the logged week (its ALTER ROLE
    # <service>_app ... statements mark a run), read from every weekday csvlog that exists (Audit's file_fdw tables pgaudit.log_<dy>, one
    # per weekday, truncated on rotation). Not the latest run: db-roles reruns roles.sql on every platform sync, and no migration need
    # follow it, so "since the latest run" can be empty without anything being wrong. Since the earliest run every CREATE TABLE in a
    # service database must be its own <service>_app's (never the superuser postgres: that is the regression this catches, before or
    # after a later roles.sql run), and at least five databases must show one, so the check cannot pass on an empty window. roles.sql
    # itself creates no plain table (only file_fdw foreign tables, CREATE FOREIGN TABLE). A weekday's table is read only when its file
    # exists (file_fdw fails on a missing file; pg_stat_file's `change` is always NULL on Linux, hence `.size`). With no roles.sql run in the week the whole
    # week is judged. A cluster idle for over a week (no run, no DDL) fails here for lack of evidence: deploy or sync, then rerun.
    $pgauditSql = @'
SELECT format($q$WITH log AS (%s),
  roles_run AS (SELECT coalesce(min(log_time), '-infinity') AS at FROM log
    WHERE message LIKE 'AUDIT: SESSION,%%,ROLE,ALTER ROLE,%%' AND message LIKE '%%\_app%%')
SELECT DISTINCT database_name || '|' || user_name FROM log, roles_run
  WHERE log_time > roles_run.at AND message LIKE 'AUDIT: SESSION,%%,DDL,CREATE TABLE,%%' AND database_name LIKE '%%db' AND database_name <> 'keycloakdb'
  ORDER BY 1$q$, string_agg(format('SELECT log_time, user_name, database_name, message FROM pgaudit.%I', 'log_' || lower(day)), ' UNION ALL '))
FROM unnest(ARRAY['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) AS day
WHERE (pg_stat_file('log/postgresql-' || day || '.csv', true)).size IS NOT NULL \gexec
'@
    $rows = $pgauditSql -replace "`r", '' | & kubectl @KubectlArgs -n procure exec -i postgres-0 -c postgres -- psql -X -q -tA -v ON_ERROR_STOP=1 -U postgres -d auditdb 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "reading the pgaudit logs in postgres-0 failed: $(($rows | Select-Object -Last 3) -join ' | ')" }
    else {
        $seen = @($rows | Where-Object { "$_" -match '^(\w+db)\|(\S+)$' } | ForEach-Object { [pscustomobject]@{ Database = $Matches[1]; Role = $Matches[2] } })
        $databases = @($seen | ForEach-Object Database | Sort-Object -Unique)
        if ($databases.Count -lt 5) { Fail "the week's pgaudit logs name CREATE TABLE since the first roles.sql run in only $($databases.Count) service database(s) (no evidence; at least 5 expected): $(($rows | Select-Object -First 5) -join ' | ')" }
        foreach ($database in $databases) {
            $expected = ($database -replace 'db$', '') + '_app'
            $roles = @($seen | Where-Object Database -eq $database | ForEach-Object Role)
            if ($roles.Count -eq 1 -and $roles[0] -ceq $expected) { Pass "pgaudit: every CREATE TABLE in $database since roles.sql first ran was run by $expected" }
            else { Fail "pgaudit: CREATE TABLE in $database since roles.sql first ran was run by $($roles -join ', '), expected only $expected" }
        }
    }

    # --- 12. The realm in Git matches the server -------------------------------------------------------------------------------------
    # The realm file of the deployed Keycloak image (infra/keycloak/procure-realm.json at the deployed revision) with its non-secret
    # placeholders filled in as the chart fills them, against Keycloak's partial export (secrets masked) read with kcadm in the pod: per
    # client of the file its redirect URIs, web origins, post-logout redirect URIs, default and optional client scopes (the full lists:
    # a client may name only scopes the realm defines, RealmFileTests) and client roles; the file's client scopes with their mappers; the realm roles (plus Keycloak's own). The keycloak-config Job
    # (plan 08 ruling 7) keeps them equal on every sync. kcadm gets the admin password from the pod's environment (KC_CLI_PASSWORD).
    $kcadmExport = @'
export KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD"; k=/opt/keycloak/bin/kcadm.sh; c=/tmp/kcadm-smoke.config
$k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --config $c >/dev/null &&
  $k create partial-export -r procure -q exportClients=true -q exportGroupsAndRoles=true -o --config $c; rc=$?; rm -f $c; exit $rc
'@
    $realmText = & kubectl @KubectlArgs -n procure exec deploy/keycloak -c keycloak -- cat /opt/keycloak/data/import/procure-realm.json 2>&1
    $realmOk = $LASTEXITCODE -eq 0
    # stdout is the export; stderr (kcadm's "Logging into ..." and any error) stays apart for the FAIL message.
    $exportOut = & kubectl @KubectlArgs -n procure exec deploy/keycloak -c keycloak -- bash -c ($kcadmExport -replace "`r", '') 2>&1
    $exportExit = $LASTEXITCODE
    $liveText = @($exportOut | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $exportErr = @($exportOut | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if (-not $realmOk) { Fail "reading the realm file from deploy/keycloak failed: $(($realmText | Select-Object -Last 3) -join ' | ')" }
    elseif ($exportExit -ne 0) { Fail "Keycloak's partial export (kcadm in deploy/keycloak) failed with exit code ${exportExit}: $(($exportErr | Select-Object -Last 3) -join ' | ')" }
    else {
        # ${NAME} and ${NAME:default}, as Keycloak and the keycloak-config Job resolve them; the secret placeholders are not compared.
        $placeholders = @{ KC_APP_BASE_URL = "https://$AppHost"; KC_DASHBOARD_BASE_URL = "https://$DashboardHost" }
        $expanded = [regex]::Replace(($realmText -join "`n"), '\$\{(KC_[A-Z0-9_]+)(?::([^}]*))?\}', {
                param($m)
                if ($placeholders.ContainsKey($m.Groups[1].Value)) { $placeholders[$m.Groups[1].Value] } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Value }
            })
        $want = $expanded | ConvertFrom-Json -AsHashtable
        $live = ($liveText -join "`n") | ConvertFrom-Json -AsHashtable
        $drift = [System.Collections.Generic.List[string]]::new()
        function Compare-Set([string] $what, $expected, $actual) {
            $e = @($expected | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive); $a = @($actual | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
            if (($e -join "`n") -cne ($a -join "`n")) { $drift.Add("$what is [$($a -join ', ')] on the server, [$($e -join ', ')] in Git") }
        }
        # Hashtables throughout ($h['key'] is $null for a missing key under strict mode).
        function Get-Names($items) { @($items | Where-Object { $_ } | ForEach-Object { $_['name'] }) }
        $wantClientRoles = if ($want['roles']) { $want['roles']['client'] }
        $liveClientRoles = if ($live['roles']) { $live['roles']['client'] }
        foreach ($client in $want['clients']) {
            $id = $client['clientId']
            $server = @($live['clients'] | Where-Object { $_['clientId'] -ceq $id }) | Select-Object -First 1
            if (-not $server) { $drift.Add("client $id is missing on the server"); continue }
            foreach ($field in 'redirectUris', 'webOrigins') { if ($client.ContainsKey($field)) { Compare-Set "client $id $field" $client[$field] $server[$field] } }
            # The full lists: offline_access (Keycloak's own scope) is named in the file where a client offers it.
            foreach ($field in 'defaultClientScopes', 'optionalClientScopes') { if ($client.ContainsKey($field)) { Compare-Set "client $id $field" $client[$field] $server[$field] } }
            $logout = if ($client['attributes']) { $client['attributes']['post.logout.redirect.uris'] }
            $liveLogout = if ($server['attributes']) { $server['attributes']['post.logout.redirect.uris'] }
            if ($logout) { Compare-Set "client $id post.logout.redirect.uris" ($logout -split '##') ("$liveLogout" -split '##') }
            Compare-Set "client $id roles" (Get-Names ($wantClientRoles ? $wantClientRoles[$id] : $null)) (Get-Names ($liveClientRoles ? $liveClientRoles[$id] : $null))
        }
        foreach ($scope in $want['clientScopes']) {
            $server = @($live['clientScopes'] | Where-Object { $_['name'] -ceq $scope['name'] }) | Select-Object -First 1
            if (-not $server) { $drift.Add("client scope $($scope['name']) is missing on the server"); continue }
            Compare-Set "client scope $($scope['name']) mappers" (Get-Names $scope['protocolMappers']) (Get-Names $server['protocolMappers'])
        }
        # Keycloak's own realm roles exist besides the file's.
        Compare-Set 'realm roles' ((Get-Names $want['roles']['realm']) + 'offline_access', 'uma_authorization', $want['defaultRole']['name']) (Get-Names $live['roles']['realm'])
        if ($drift.Count -eq 0) { Pass "the realm in Git matches the server ($(@($want['clients']).Count) clients, $(@($want['clientScopes']).Count) client scopes, realm and client roles)" }
        else { foreach ($d in $drift) { Fail "realm drift: $d" } }
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
