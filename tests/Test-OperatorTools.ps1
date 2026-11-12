#Requires -Version 7.4
<#
.SYNOPSIS
    The operator's direct access (plan 08b Task 4, Dale 2026-11-08): only Dale and Claude can sign in to any tool or reach a data store.
.DESCRIPTION
    Every tool sits on its own public host with its own login (not Keycloak's demo realm, not the gateway), so Dale can debug from any
    browser when parts of the site are down. This test proves, from Dale's PC, against -Environment hosted or local:
      1. TLS: each host answers over https with a certificate valid for its name (curl's normal verification; -SkipCertificateCheck before
         the DNS records and the certificate exist, together with -ResolveTo <VM address>).
      2. Anonymous requests are refused with the tool's OWN login (never a redirect to Keycloak's demo realm):
           pgadmin    / -> 302 to /login, /browser/ -> 302 to /login
           mongo      401 with WWW-Authenticate Basic (DbGate)
           redis      401 with WWW-Authenticate Basic (Traefik, realm "procure operator")
           rabbitmq   /api/overview -> 401
           keycloak   /admin/realms/master -> 401; the admin console signs in at /realms/master (password AND one-time code)
           dashboard  401 with WWW-Authenticate Basic (Traefik, realm "procure operator"), never a redirect to Keycloak
      3. Wrong credentials are refused on every tool: every demo user of the procure realm with the demo password (as e-mail and as name),
         and default credentials (admin/admin, guest/guest, admin@admin.com/admin, pgadmin4@pgadmin.org/admin, root/root, operator/operator).
      4. The right credentials (DEMO PASSWORDS.txt, read like bootstrap/hosted/Get-OperatorLogin.ps1) are accepted, and where the tool has a
         one-time code it is REQUIRED: pgAdmin's password alone leads to /mfa/validate and /browser/ stays closed until the code;
         Keycloak's `operator` gets no token from a password grant without the code, and the browser sign-in asks for it. Session cookies
         are Secure and HttpOnly (pgAdmin; Keycloak's KEYCLOAK_IDENTITY; KEYCLOAK_SESSION Secure only, Keycloak's own design: its
         scripts read it). RabbitMQ has no `guest` user. Each tool's default (read-only) connection really connects: pgAdmin's
         "procure (read-only)" server (password from the mounted Secret), DbGate's read-only connection lists the databases, Redis
         Insight's connection answers. The break-glass dashboard's Blazor WebSocket keeps its Origin check behind the login.
      5. The raw store and broker ports (5432, 27017, 6379, 5672, 15672, and the Kubernetes API) do not answer on the VM's public address
         (hosted only).
      6. The read-only users cannot write (through the SSH tunnel, kubectl exec in the store pods): operator_reader reads but cannot INSERT /
         CREATE in Postgres, cannot connect to keycloakdb at all (ruling R1), cannot insertOne in MongoDB, and Redis refuses SET, DEL, KEYS,
         FLUSHALL, CONFIG and DEBUG while GET and SCAN work.
      7. Every host has a rate limit: its Ingress names the rate-limit middleware (kubectl), and a burst of -RateLimitBurst parallel
         anonymous requests gets 429s (runs last: it uses up this PC's bucket for a minute). -SkipRateLimit leaves the burst out.
    Prints names and status codes only, never a password, token or TOTP secret (credentials go to curl on stdin). Exit code 1 on any failure.
.EXAMPLE
    ./tests/Test-OperatorTools.ps1                                   # hosted, after the DNS records and the certificate exist
    ./tests/Test-OperatorTools.ps1 -ResolveTo 45.13.235.178 -SkipCertificateCheck -Only pgadmin,mongo,redis,rabbitmq
    ./tests/Test-OperatorTools.ps1 -Environment local
#>
[CmdletBinding()]
param(
    [ValidateSet('hosted', 'local')]
    [string] $Environment = 'hosted',
    [ValidateSet('pgadmin', 'mongo', 'redis', 'rabbitmq', 'keycloak', 'dashboard')]
    [string[]] $Only = @('pgadmin', 'mongo', 'redis', 'rabbitmq', 'keycloak', 'dashboard'),
    # Send every request to this address (before the DNS records exist).
    [string] $ResolveTo,
    # Do not verify certificates (before the public certificate names the new hosts). Step 1 then only reports.
    [switch] $SkipCertificateCheck,
    [switch] $SkipReadOnly,
    [switch] $SkipRateLimit,
    [ValidateRange(120, 1000)] [int] $RateLimitBurst = 160,
    [string] $Path
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }
function Write-Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }

$hosted = $Environment -eq 'hosted'
$domain = if ($hosted) { $HostedDomain } else { 'procure.localtest.me' }
$secrets = Read-OperatorSecrets -Environment $Environment -Path ($Path ? $Path : $DemoPasswordsFile)
function Get-Secret([string] $name) {
    $value = $secrets[$name]
    if ([string]::IsNullOrEmpty($value)) { throw "No entry '$name' in DEMO PASSWORDS.txt (bootstrap/new-secrets.ps1$(if ($hosted) { ' -Environment hosted' }))." }
    $value
}
$hostOf = @{ pgadmin = "pgadmin.$domain"; mongo = "mongo.$domain"; redis = "redis.$domain"; rabbitmq = "rabbitmq.$domain"
    keycloak = "auth.$domain"; dashboard = "dashboard-direct.$domain" }
$curl = @("$env:SystemRoot\System32\curl.exe", 'C:\Program Files\Git\mingw64\bin\curl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-operator-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

function ConvertTo-CurlString([string] $value) { '"' + ($value -replace '\\', '\\' -replace '"', '\"') + '"' }

function Invoke-Http {
    # One request through curl, configured on stdin (credentials never reach a command line). No redirect is followed. -Form: fields sent
    # url-encoded (POST); -Body: a raw request body. -User/-Password: basic auth. -Jar: a cookie file kept between calls. Returns Status, Location, Body, Headers,
    # Cookies (the Set-Cookie lines).
    param([Parameter(Mandatory)] [string] $Url, [string] $Method, [System.Collections.IDictionary] $Form, [string] $User, [string] $Password,
        [string] $Jar, [hashtable] $Header = @{}, [switch] $Verify, [string] $Body)
    $bodyFile = Join-Path $work 'body.txt'; $headerFile = Join-Path $work 'headers.txt'
    Remove-Item $bodyFile, $headerFile -ErrorAction SilentlyContinue
    $uri = [Uri] $Url
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("url = $(ConvertTo-CurlString $Url)")
    $lines.Add('silent'); $lines.Add('show-error'); $lines.Add('max-time = 20'); $lines.Add('ssl-no-revoke')
    if ($SkipCertificateCheck -and -not $Verify) { $lines.Add('insecure') }
    if ($ResolveTo) { $lines.Add("resolve = $(ConvertTo-CurlString "$($uri.Host):$($uri.Port):$ResolveTo")") }
    if ($Method) { $lines.Add("request = $(ConvertTo-CurlString $Method)") }
    if ($User) { $lines.Add("user = $(ConvertTo-CurlString "$($User):$Password")") }
    foreach ($key in $Header.Keys) { $lines.Add("header = $(ConvertTo-CurlString "$($key): $($Header[$key])")") }
    if ($Form) { foreach ($key in $Form.Keys) { $lines.Add("data-urlencode = $(ConvertTo-CurlString "$key=$($Form[$key])")") } }
    if ($Body) { $lines.Add("data-binary = $(ConvertTo-CurlString $Body)") }
    if ($Jar) { $lines.Add("cookie = $(ConvertTo-CurlString $Jar)"); $lines.Add("cookie-jar = $(ConvertTo-CurlString $Jar)") }
    $lines.Add("output = $(ConvertTo-CurlString $bodyFile)"); $lines.Add("dump-header = $(ConvertTo-CurlString $headerFile)")
    $lines.Add('write-out = "%{http_code}"')
    $out = ($lines -join "`n") | & $curl --config - 2>&1
    $status = if ("$out" -match '(\d{3})$') { [int] $Matches[1] } else { 0 }
    $headers = @(Get-Content $headerFile -ErrorAction SilentlyContinue | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $location = $headers | Where-Object { $_ -match '^location:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -Last 1
    $body = if (Test-Path $bodyFile) { Get-Content -Raw $bodyFile } else { '' }
    [pscustomobject]@{ Status = $status; Location = "$location"; Body = "$body"; Headers = $headers; Error = "$out"
        Cookies = @($headers | Where-Object { $_ -match '^set-cookie:' }) }
}

function Test-CookieFlags([string] $tool, [object[]] $cookies, [string[]] $SecureOnly = @()) {
    # Session cookies: Secure (https only) and HttpOnly (not readable by scripts). Cookies being deleted (expired) are ignored. -SecureOnly:
    # cookie names that must be Secure but are readable by scripts by the tool's own design (Keycloak's KEYCLOAK_SESSION).
    $live = @($cookies | Where-Object { $_ -notmatch 'Max-Age=0|expires=Thu, 01[- ]Jan[- ]1970' })
    if ($live.Count -eq 0) { Fail "$($tool): no session cookie seen"; return }
    foreach ($c in $live) {
        $name = ($c -replace '^set-cookie:\s*', '' -split '=')[0]
        $secure = $c -match '(?i);\s*secure'
        if ($name -in $SecureOnly) {
            if ($secure) { Pass "$tool cookie $name is Secure (scripts may read it: $tool's design)" } else { Fail "$tool cookie $name is not Secure" }
        } elseif ($secure -and $c -match '(?i);\s*httponly') { Pass "$tool cookie $name is Secure and HttpOnly" }
        else { Fail "$tool cookie $name lacks Secure or HttpOnly" }
    }
}

# Credentials that must never get in: the demo realm's users with the demo password, and well-known defaults.
$demoPassword = $secrets['keycloak-demo-password']
$demoUsers = 'tom@acme.test', 'maria@acme.test', 'dept@acme.test', 'thandi@acme.test', 'admin@acme.test', 'ben@globex.test', 'approver@demo.test'
$wrong = [System.Collections.Generic.List[object]]::new()
if ($demoPassword) {
    foreach ($u in $demoUsers) { $wrong.Add(@($u, $demoPassword)); $wrong.Add(@(($u -split '@')[0], $demoPassword)) }
} else { Fail 'keycloak-demo-password is not in DEMO PASSWORDS.txt: the demo users cannot be tried' }
foreach ($pair in @('admin', 'admin'), @('guest', 'guest'), @('admin@admin.com', 'admin'), @('pgadmin4@pgadmin.org', 'admin'), @('root', 'root'),
    @('operator', 'operator'), @('admin', 'password')) { $wrong.Add($pair) }

try {
    # --- 1. TLS ------------------------------------------------------------------------------------------------------------------------
    Write-Step "TLS ($Environment)"
    foreach ($tool in $Only) {
        $r = Invoke-Http "https://$($hostOf[$tool])/" -Verify
        if ($r.Status -gt 0) { Pass "https://$($hostOf[$tool])/ answers ($($r.Status)) with a certificate valid for its name" }
        elseif ($SkipCertificateCheck) { Write-Host "note: https://$($hostOf[$tool])/ certificate not valid yet (-SkipCertificateCheck): $($r.Error)" -ForegroundColor Yellow }
        else { Fail "https://$($hostOf[$tool])/: $($r.Error)" }
    }

    # --- 2-4. Each tool ------------------------------------------------------------------------------------------------------------------
    if ('pgadmin' -in $Only) {
        $base = "https://$($hostOf.pgadmin)"
        Write-Step "pgAdmin ($base)"
        foreach ($p in '/', '/browser/') {
            $r = Invoke-Http "$base$p"
            if ($r.Status -eq 302 -and $r.Location -match '/login' -and $r.Location -notmatch '/realms/') { Pass "anonymous $p -> 302 to pgAdmin's own /login" }
            else { Fail "anonymous $base$p answered $($r.Status) Location '$($r.Location)', expected 302 to /login" }
        }
        function Invoke-PgAdminLogin([string] $email, [string] $password, [string] $jar) {
            $page = Invoke-Http "$base/login" -Jar $jar
            $csrf = if ($page.Body -match '"csrfToken":\s*"([^"]+)"') { $Matches[1] } else { '' }
            if (-not $csrf) { Fail 'pgAdmin login page has no csrfToken'; return $null }
            $r = Invoke-Http "$base/authenticate/login" -Method POST -Jar $jar -Form ([ordered]@{ csrf_token = $csrf; email = $email; password = $password; language = 'en'; internal_button = 'Login' })
            [pscustomobject]@{ Response = $r; Csrf = $csrf; Login = $page }
        }
        $refused = 0
        foreach ($pair in $wrong) {
            $jar = Join-Path $work "pg-wrong.jar"; Remove-Item $jar -ErrorAction SilentlyContinue
            $l = Invoke-PgAdminLogin $pair[0] $pair[1] $jar
            if (-not $l) { continue }
            $after = Invoke-Http "$base/browser/" -Jar $jar
            if ($after.Status -eq 302 -and $after.Location -match '/login' -and $after.Location -notmatch '/mfa/') { $refused++ }
            else { Fail "pgAdmin let '$($pair[0])' (wrong credentials) past the login: /browser/ answered $($after.Status) $($after.Location)" }
        }
        Pass "pgAdmin refused all $refused wrong credential pairs (demo users, defaults)"
        $jar = Join-Path $work 'pg.jar'
        $l = Invoke-PgAdminLogin $(if ($hosted) { "operator@$domain" } else { 'operator@procure.localtest.me' }) (Get-Secret 'operator-pgadmin-password') $jar
        if ($l) {
            Test-CookieFlags 'pgAdmin' $l.Login.Cookies
            $before = Invoke-Http "$base/browser/" -Jar $jar
            if ($before.Status -eq 302 -and $before.Location -match '/mfa/') { Pass 'the right password alone does not open pgAdmin: /browser/ -> the one-time code page' }
            else { Fail "after the password only, /browser/ answered $($before.Status) '$($before.Location)', expected 302 to /mfa/..." }
            $mfa = Invoke-Http "$base/mfa/validate" -Jar $jar
            $csrf = if ($mfa.Body -match '"csrfToken":\s*"([^"]+)"') { $Matches[1] } elseif ($mfa.Body -match 'name="csrf_token"[^>]*value="([^"]+)"') { $Matches[1] } else { $l.Csrf }
            $wrongCode = Invoke-Http "$base/mfa/validate" -Method POST -Jar $jar -Form ([ordered]@{ csrf_token = $csrf; mfa_method = 'authenticator'; code = '000000'; next = '/browser/' })
            $still = Invoke-Http "$base/browser/" -Jar $jar
            if ($still.Status -eq 302) { Pass 'a wrong one-time code keeps pgAdmin closed' } else { Fail "with a wrong code /browser/ answered $($still.Status)" }
            $code = (Get-TotpCode (Get-Secret 'operator-pgadmin-totp-base32') -OffsetSeconds ([int] (Get-ServerClockOffset $base $ResolveTo))).Code
            $null = Invoke-Http "$base/mfa/validate" -Method POST -Jar $jar -Form ([ordered]@{ csrf_token = $csrf; mfa_method = 'authenticator'; code = $code; next = '/browser/' })
            $open = Invoke-Http "$base/browser/" -Jar $jar
            if ($open.Status -eq 200) { Pass 'pgAdmin opens with the password AND the current one-time code (DEMO PASSWORDS.txt)' }
            else { Fail "with the right password and code /browser/ answered $($open.Status) '$($open.Location)'" }
            # Its default server connects as operator_reader, the password coming from the mounted Secret (PasswordExecCommand), never stored.
            $token = if ($open.Body -match 'csrfToken["'']?\s*[:=]\s*["'']([^"'']+)') { $Matches[1] } else { $csrf }
            # pgAdmin's API wants its CSRF token and (https, Flask-WTF strict referrer check) a Referer from its own site, as the browser sends.
            $pgHeader = @{ 'X-pgA-CSRFToken' = $token; Referer = "$base/browser/" }
            function Read-PgAdminData($response) {
                # The payload of a pgAdmin API answer ({"success": 1, "data": ...}; node lists put it in "result"), or nothing.
                $json = try { $response.Body | ConvertFrom-Json -AsHashtable } catch { $null }
                if ($json -isnot [System.Collections.IDictionary]) { return }
                foreach ($key in 'data', 'result') { if ($json.Contains($key) -and $null -ne $json[$key]) { return $json[$key] } }
            }
            $groups = Invoke-Http "$base/browser/server_group/nodes/" -Jar $jar -Header $pgHeader
            $servers = foreach ($g in @(Read-PgAdminData $groups | Where-Object { $_ })) {
                $list = Invoke-Http "$base/browser/server/nodes/$($g['_id'])/" -Jar $jar -Header $pgHeader
                @(Read-PgAdminData $list | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ Group = $g['_id']; Id = $_['_id']; Label = $_['label'] } }
            }
            $reader = @($servers | Where-Object { $_.Label -match 'read-only' }) | Select-Object -First 1
            if (-not $reader) { Fail "pgAdmin lists no read-only server (server groups: $($groups.Status) $(($groups.Body -replace '\s+', ' ').Substring(0, [Math]::Min(160, $groups.Body.Length))); servers: $(@($servers | ForEach-Object { $_.Label }) -join ', '))" }
            else {
                $c = Invoke-Http "$base/browser/server/connect/$($reader.Group)/$($reader.Id)" -Method POST -Jar $jar -Header $pgHeader -Form ([ordered]@{ dummy = '1' })
                $data = Read-PgAdminData $c
                $connected = $data -is [System.Collections.IDictionary] -and $data.Contains('connected') -and $data['connected']
                if ($c.Status -eq 200 -and $connected) { Pass "pgAdmin's '$($reader.Label)' server connects (operator_reader, password from the Secret)" }
                else { Fail "pgAdmin's '$($reader.Label)' server did not connect: $($c.Status) $(($c.Body -replace '\s+', ' ').Substring(0, [Math]::Min(200, $c.Body.Length)))" }
            }
        }
    }

    if ('mongo' -in $Only) {
        $base = "https://$($hostOf.mongo)"
        Write-Step "MongoDB UI, DbGate ($base)"
        $r = Invoke-Http "$base/"
        if ($r.Status -eq 401 -and ($r.Headers -match '^www-authenticate:\s*Basic')) { Pass 'anonymous -> 401 with its own basic-auth login' }
        else { Fail "anonymous $base/ answered $($r.Status), expected 401 Basic" }
        $refused = @($wrong | Where-Object { (Invoke-Http "$base/" -User $_[0] -Password $_[1]).Status -eq 401 }).Count
        if ($refused -eq $wrong.Count) { Pass "DbGate refused all $refused wrong credential pairs" } else { Fail "DbGate accepted $($wrong.Count - $refused) wrong credential pair(s)" }
        $password = Get-Secret 'operator-mongo-ui-password'
        $r = Invoke-Http "$base/" -User 'operator' -Password $password
        if ($r.Status -eq 200) { Pass 'DbGate opens with its own login (DEMO PASSWORDS.txt)' } else { Fail "DbGate with the right login answered $($r.Status)" }
        # Its read-only connection reaches MongoDB as operator_reader (DbGate opens it on the first call; a few tries).
        $names = @()
        foreach ($try in 1..5) {
            $r = Invoke-Http "$base/server-connections/list-databases" -Method POST -User 'operator' -Password $password -Header @{ 'Content-Type' = 'application/json' } -Body '{"conid":"reader"}'
            $names = @(try { @($r.Body | ConvertFrom-Json) | ForEach-Object { $_.name } } catch { })
            if ('suppliersdb' -in $names) { break }
            Start-Sleep -Seconds 2
        }
        if ('suppliersdb' -in $names) { Pass "DbGate's read-only connection lists the databases ($($names -join ', '))" } else { Fail "DbGate's read-only connection listed no databases ($($r.Status))" }
    }

    if ('redis' -in $Only) {
        $base = "https://$($hostOf.redis)"
        Write-Step "Redis Insight ($base)"
        $r = Invoke-Http "$base/"
        if ($r.Status -eq 401 -and ($r.Headers -match '^www-authenticate:\s*Basic realm="procure operator"')) { Pass 'anonymous -> 401 with the basic-auth login in front of it' }
        else { Fail "anonymous $base/ answered $($r.Status), expected 401 Basic" }
        $refused = @($wrong | Where-Object { (Invoke-Http "$base/" -User $_[0] -Password $_[1]).Status -eq 401 }).Count
        if ($refused -eq $wrong.Count) { Pass "Redis Insight's login refused all $refused wrong credential pairs" } else { Fail "Redis Insight's login accepted $($wrong.Count - $refused) wrong pair(s)" }
        $password = Get-Secret 'operator-redis-insight-password'
        $r = Invoke-Http "$base/" -User 'operator' -Password $password
        if ($r.Status -eq 200) { Pass 'Redis Insight opens with its login (DEMO PASSWORDS.txt)' } else { Fail "Redis Insight with the right login answered $($r.Status)" }
        $r = Invoke-Http "$base/api/databases" -User 'operator' -Password $password
        $dbs = try { @($r.Body | ConvertFrom-Json) } catch { @() }
        $db = @($dbs | Where-Object { $_.name -eq 'procure Redis (read-only)' }) | Select-Object -First 1
        if ($r.Status -eq 200 -and $db) { Pass "its connection is 'procure Redis (read-only)' (ACL user operator_reader)" }
        else { Fail "Redis Insight's databases: $($r.Status), no operator_reader connection" }
        if ($db) {
            $info = Invoke-Http "$base/api/databases/$($db.id)/info" -User 'operator' -Password $password
            $keys = try { ($info.Body | ConvertFrom-Json).totalKeys } catch { $null }
            if ($info.Status -eq 200 -and $null -ne $keys) { Pass "Redis Insight connects as operator_reader ($keys keys)" } else { Fail "Redis Insight's connection info answered $($info.Status)" }
        }
    }

    if ('rabbitmq' -in $Only) {
        $base = "https://$($hostOf.rabbitmq)"
        Write-Step "RabbitMQ management ($base)"
        $r = Invoke-Http "$base/api/overview"
        if ($r.Status -eq 401) { Pass 'anonymous /api/overview -> 401' } else { Fail "anonymous /api/overview answered $($r.Status)" }
        $refused = @($wrong | Where-Object { (Invoke-Http "$base/api/whoami" -User $_[0] -Password $_[1]).Status -eq 401 }).Count
        if ($refused -eq $wrong.Count) { Pass "RabbitMQ refused all $refused wrong credential pairs (guest/guest included)" } else { Fail "RabbitMQ accepted $($wrong.Count - $refused) wrong pair(s)" }
        $password = Get-Secret 'operator-rabbitmq-password'
        $r = Invoke-Http "$base/api/whoami" -User 'operator' -Password $password
        if ($r.Status -eq 200 -and ($r.Body | ConvertFrom-Json).name -eq 'operator') { Pass "the operator's own management user signs in" } else { Fail "operator's /api/whoami answered $($r.Status)" }
        $r = Invoke-Http "$base/api/users" -User 'operator' -Password $password
        $users = if ($r.Status -eq 200) { @(($r.Body | ConvertFrom-Json).name) } else { @() }
        if ($r.Status -eq 200 -and 'guest' -notin $users) { Pass "no guest user ($($users.Count) users: the apps' and the operator's)" }
        elseif ($hosted) { Fail "RabbitMQ users: $($r.Status) [$($users -join ', ')]: guest must not exist on the public host" }
        else { Write-Host 'note: the local cluster runs the apps as guest (not public)' -ForegroundColor Yellow }
        # Fix round 1 I2: the apps' shared user has no management tag, so its password (which the services and Debezium hold) is no admin
        # login on this public host; its AMQP connections are unaffected (the services and Debezium are connected as it).
        $appUser = if ($secrets['rabbitmq-username']) { $secrets['rabbitmq-username'] } else { 'guest' }
        $r = Invoke-Http "$base/api/overview" -User $appUser -Password (Get-Secret 'rabbitmq-password')
        if ($r.Status -eq 401) { Pass "the apps' user $appUser cannot sign in to the management API (401)" } else { Fail "the apps' user $appUser on /api/overview: $($r.Status), expected 401" }
        $r = Invoke-Http "$base/api/users/$appUser" -User 'operator' -Password $password
        $tags = if ($r.Status -eq 200) { @(@(($r.Body | ConvertFrom-Json).tags) | Where-Object { $_ }) } else { @('?') }
        if ($r.Status -eq 200 -and @($tags).Count -eq 0) { Pass "the apps' user $appUser has no tags (AMQP only)" } else { Fail "the apps' user $appUser tags: [$($tags -join ', ')] ($($r.Status))" }
        $r = Invoke-Http "$base/api/connections?columns=user,client_properties.connection_name" -User 'operator' -Password $password
        $connections = if ($r.Status -eq 200) { @($r.Body | ConvertFrom-Json | Where-Object { $_.user -eq $appUser }) } else { @() }
        if (@($connections).Count -gt 0) { Pass "the services and Debezium are connected over AMQP as $appUser ($(@($connections).Count) connections)" }
        else { Fail "no AMQP connection as $appUser ($($r.Status)): the apps cannot reach the broker" }
    }

    if ('keycloak' -in $Only) {
        $base = "https://$($hostOf.keycloak)"
        Write-Step "Keycloak admin console ($base/admin/master/console/)"
        $r = Invoke-Http "$base/admin/realms/master"
        if ($r.Status -eq 401) { Pass 'the admin REST API answers 401 without a token' } else { Fail "/admin/realms/master answered $($r.Status)" }
        $tokenUrl = "$base/realms/master/protocol/openid-connect/token"
        # Demo users and defaults get no token. (The demo users do not exist in master; no real account gets a failed attempt.)
        # Keycloak 26.8 answers a refused password grant with 400 invalid_grant (401 in older versions); a token is 200 with access_token.
        function Test-Refused($r) { $r.Status -in 400, 401 -and $r.Body -match 'invalid_grant|unauthorized' -and $r.Body -notmatch 'access_token' }
        $refused = @($wrong | Where-Object { Test-Refused (Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'password'; client_id = 'admin-cli'; username = $_[0]; password = $_[1] })) }).Count
        if ($refused -eq $wrong.Count) { Pass "the master realm refused all $refused wrong credential pairs" } else { Fail "the master realm did not refuse $($wrong.Count - $refused) wrong pair(s)" }
        $password = Get-Secret 'operator-keycloak-password'
        $r = Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'password'; client_id = 'admin-cli'; username = 'operator'; password = $password })
        if (Test-Refused $r) { Pass "operator's password alone gets no token ($($r.Status): the one-time code is required)" } else { Fail "operator's password alone: $($r.Status), expected 400/401 invalid_grant" }
        # Fix round 1 (review I3/R3): the bootstrap admin is disabled (break-glass only) and, like every master-realm user, would need a code
        # anyway; the automation signs in as the confidential client procure-automation (client credentials, no user to lock out).
        $r = Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'password'; client_id = 'admin-cli'; username = $(if ($secrets['keycloak-admin']) { $secrets['keycloak-admin'] } else { 'keycloak-admin' }); password = (Get-Secret 'keycloak-admin-password') })
        if (Test-Refused $r) { Pass "the bootstrap admin's password gets no token ($($r.Status) $(if ($r.Body -match 'disabled') { 'account disabled' } else { 'refused' }))" }
        else { Fail "the bootstrap admin's password: $($r.Status), expected a refusal" }
        $r = Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'client_credentials'; client_id = 'procure-automation'; client_secret = (Get-Secret 'keycloak-automation-client-secret') })
        $adminToken = if ($r.Status -eq 200) { try { ($r.Body | ConvertFrom-Json).access_token } catch { $null } }
        if ($adminToken) { Pass 'the automation client procure-automation gets a token with its secret (client credentials)' } else { Fail "procure-automation client credentials: $($r.Status)" }
        $r = Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'password'; client_id = 'procure-automation'; client_secret = (Get-Secret 'keycloak-automation-client-secret'); username = 'operator'; password = $password; totp = '000000' })
        if ($r.Status -in 400, 401 -and $r.Body -notmatch 'access_token') { Pass "procure-automation allows no password grant ($($r.Status))" } else { Fail "procure-automation password grant: $($r.Status), expected a refusal" }
        if ($adminToken) {
            $adminName = if ($secrets['keycloak-admin']) { $secrets['keycloak-admin'] } else { 'keycloak-admin' }
            $r = Invoke-Http "$base/admin/realms/master/users?exact=true&username=$([uri]::EscapeDataString($adminName))" -Header @{ Authorization = "Bearer $adminToken" }
            $found = try { @($r.Body | ConvertFrom-Json) } catch { @() }
            if ($r.Status -eq 200 -and @($found).Count -eq 1 -and -not @($found)[0].enabled) { Pass "the bootstrap admin $adminName exists and is disabled (break-glass)" }
            else { Fail "the bootstrap admin ${adminName}: $($r.Status), $(@($found).Count) found, enabled $($found | ForEach-Object enabled)" }
            $r = Invoke-Http "$base/admin/realms/master" -Header @{ Authorization = "Bearer $adminToken" }
            $realm = try { $r.Body | ConvertFrom-Json } catch { $null }
            if ($realm -and $realm.directGrantFlow -eq 'operator direct grant' -and $realm.browserFlow -eq 'operator browser') { Pass "the master realm binds 'operator browser' and 'operator direct grant' (one-time code for every password sign-in)" }
            else { Fail "the master realm's flows: browser '$($realm.browserFlow)', direct grant '$($realm.directGrantFlow)'" }
            $adminToken = $null
        }
        # The browser sign-in of the admin console: password, then the one-time code, then the redirect with an authorization code.
        $verifier = -join ((1..64) | ForEach-Object { 'abcdefghijklmnopqrstuvwxyz0123456789'[(Get-Random -Maximum 36)] })
        $challenge = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $redirect = "$base/admin/master/console/"
        $jar = Join-Path $work 'kc.jar'
        $auth = Invoke-Http ("$base/realms/master/protocol/openid-connect/auth?client_id=security-admin-console&response_type=code&scope=openid" +
            "&redirect_uri=$([uri]::EscapeDataString($redirect))&code_challenge=$challenge&code_challenge_method=S256&state=t&nonce=t") -Jar $jar
        $action = if ($auth.Body -match 'action="([^"]+)"') { [Net.WebUtility]::HtmlDecode($Matches[1]) } else { '' }
        if (-not $action) { Fail "the master realm's sign-in page answered $($auth.Status) without a form" }
        else {
            $step = Invoke-Http $action -Method POST -Jar $jar -Form ([ordered]@{ username = 'operator'; password = $password; credentialId = '' })
            if ($step.Status -eq 200 -and $step.Body -match 'name="otp"') { Pass 'after the right password the console asks for the one-time code' }
            else { Fail "after the password the sign-in answered $($step.Status) '$($step.Location)' without an OTP field" }
            $otpAction = if ($step.Body -match 'action="([^"]+)"') { [Net.WebUtility]::HtmlDecode($Matches[1]) } else { '' }
            $done = Invoke-Http $otpAction -Method POST -Jar $jar -Form ([ordered]@{ otp = (Get-TotpCode (Get-Secret 'operator-keycloak-totp-base32') -OffsetSeconds ([int] (Get-ServerClockOffset $base $ResolveTo))).Code })
            if ($done.Status -eq 302 -and $done.Location.StartsWith($redirect) -and $done.Location -match '[?&#]code=') { Pass 'with the one-time code the console gets its authorization code (operator signed in)' }
            else { Fail "after the one-time code the sign-in answered $($done.Status) '$($done.Location)'" }
            Test-CookieFlags 'Keycloak' @($done.Cookies | Where-Object { $_ -match 'KEYCLOAK_SESSION|KEYCLOAK_IDENTITY' }) -SecureOnly 'KEYCLOAK_SESSION'
        }
        # A password grant with the password AND a code works (direct grant flow "operator direct grant", fix round 1). A code is good once
        # (Keycloak's OTP policy: not reusable), so wait for the next 30-second step after the browser sign-in's code.
        $offset = [int] (Get-ServerClockOffset $base $ResolveTo)
        Start-Sleep -Seconds ((Get-TotpCode (Get-Secret 'operator-keycloak-totp-base32') -OffsetSeconds $offset).SecondsLeft + 1)
        $code = (Get-TotpCode (Get-Secret 'operator-keycloak-totp-base32') -OffsetSeconds $offset).Code
        $r = Invoke-Http $tokenUrl -Method POST -Form ([ordered]@{ grant_type = 'password'; client_id = 'admin-cli'; username = 'operator'; password = $password; totp = $code })
        if ($r.Status -eq 200 -and $r.Body -match 'access_token') { Pass "operator's password AND the current one-time code get a token (OTP REQUIRED in password grants)" }
        else { Fail "operator's password and code: $($r.Status), expected 200 with a token" }
    }

    if ('dashboard' -in $Only) {
        $base = "https://$($hostOf.dashboard)"
        Write-Step "Break-glass dashboard ($base)"
        foreach ($p in '/', '/structuredlogs', '/_blazor') {
            $r = Invoke-Http "$base$p"
            if ($r.Status -eq 401 -and ($r.Headers -match '^www-authenticate:\s*Basic realm="procure operator"')) { Pass "anonymous $p -> 401 with the basic-auth login in front of it (not Keycloak)" }
            else { Fail "anonymous $base$p answered $($r.Status) '$($r.Location)', expected 401 Basic" }
        }
        $refused = @($wrong | Where-Object { (Invoke-Http "$base/structuredlogs" -User $_[0] -Password $_[1]).Status -eq 401 }).Count
        if ($refused -eq $wrong.Count) { Pass "the dashboard's login refused all $refused wrong credential pairs" } else { Fail "the dashboard's login accepted $($wrong.Count - $refused) wrong pair(s)" }
        $password = Get-Secret 'operator-dashboard-token'
        $r = Invoke-Http "$base/structuredlogs" -User 'operator' -Password $password
        if ($r.Status -eq 200 -and $r.Body -match '<html') { Pass 'the dashboard opens with its login (DEMO PASSWORDS.txt operator-dashboard-token), no Keycloak' }
        else { Fail "the dashboard with the right login answered $($r.Status) '$($r.Location)'" }
        # Blazor's WebSocket behind the login: the origin check still holds (a foreign Origin 403, its own passes it).
        $ws = @{ Connection = 'Upgrade'; Upgrade = 'websocket'; 'Sec-WebSocket-Version' = '13'; 'Sec-WebSocket-Key' = 'dGhlIHNhbXBsZSBub25jZQ==' }
        $own = Invoke-Http "$base/_blazor?id=operator-probe" -User 'operator' -Password $password -Header ($ws + @{ Origin = $base })
        $foreign = Invoke-Http "$base/_blazor?id=operator-probe" -User 'operator' -Password $password -Header ($ws + @{ Origin = 'https://evil.example' })
        if ($foreign.Status -eq 403 -and $own.Status -in 400, 404) { Pass "its WebSocket: own Origin passes the origin check ($($own.Status) unknown circuit), a foreign one gets 403" }
        else { Fail "dashboard WebSocket: own Origin $($own.Status), foreign $($foreign.Status) (expected 400/404 and 403)" }
    }

    # --- 4b. Cross-site requests (fix round 1, review M5) ----------------------------------------------------------------------------
    # A browser sends a cached basic-auth login (and cookies) with requests other sites make, and a text/plain POST needs no CORS preflight
    # (RabbitMQ's management API published a message that way before the guard). Every request with a foreign Origin gets 403 from Traefik,
    # with the right login too; the tool's own Origin and requests without one pass.
    $originProbes = [ordered]@{
        pgadmin  = @{ Path = '/login'; User = ''; Password = '' }
        mongo    = @{ Path = '/'; User = 'operator'; Password = $(if ('mongo' -in $Only) { Get-Secret 'operator-mongo-ui-password' }) }
        redis    = @{ Path = '/'; User = 'operator'; Password = $(if ('redis' -in $Only) { Get-Secret 'operator-redis-insight-password' }) }
        rabbitmq = @{ Path = '/api/overview'; User = 'operator'; Password = $(if ('rabbitmq' -in $Only) { Get-Secret 'operator-rabbitmq-password' }) }
    }
    $originTools = @($Only | Where-Object { $originProbes.Contains($_) })
    if ($originTools) { Write-Step 'Cross-site requests (a foreign Origin) are refused' }
    foreach ($tool in $originTools) {
        $p = $originProbes[$tool]; $base = "https://$($hostOf[$tool])"
        $foreign = Invoke-Http "$base$($p.Path)" -Method POST -User $p.User -Password $p.Password -Header @{ Origin = 'https://evil.example'; 'Content-Type' = 'text/plain' } -Body 'operator-origin-probe'
        $foreignGet = Invoke-Http "$base$($p.Path)" -User $p.User -Password $p.Password -Header @{ Origin = 'https://evil.example' }
        $own = Invoke-Http "$base$($p.Path)" -User $p.User -Password $p.Password -Header @{ Origin = $base }
        if ($foreign.Status -eq 403 -and $foreignGet.Status -eq 403 -and $own.Status -ne 403) { Pass "$($tool): a foreign Origin gets 403 (POST and GET, with the right login), its own Origin $($own.Status)" }
        else { Fail "$($tool): foreign Origin POST $($foreign.Status), GET $($foreignGet.Status) (expected 403); own Origin $($own.Status)" }
    }

    # --- 5. Raw ports closed from the internet ---------------------------------------------------------------------------------------
    if ($hosted) {
        Write-Step 'Raw store, broker and API ports on the public address'
        $ip = $ResolveTo ? $ResolveTo : (Get-HostedHost).ipv4
        foreach ($port in 5432, 27017, 6379, 5672, 15672, 6443, 16443, 3000, 5540, 8080) {
            $client = [System.Net.Sockets.TcpClient]::new()
            $open = try { $client.ConnectAsync($ip, $port).Wait(3000) -and $client.Connected } catch { $false } finally { $client.Dispose() }
            if (-not $open) { Pass "$($ip):$port does not answer" } else { Fail "$($ip):$port answers from the internet" }
        }
    }

    # --- 6. Read-only users ---------------------------------------------------------------------------------------------------------
    if (-not $SkipReadOnly) {
        Write-Step 'The read-only users cannot write (kubectl exec in the store pods)'
        Select-ProcureCluster $Environment
        Assert-ClusterReachable
        function Invoke-InPod([string] $target, [string] $container, [string] $secret, [string] $script) {
            # The secret is the first line of stdin, the script reads it with `read`; nothing secret on a command line.
            $containerArgs = if ($container) { @('-c', $container) } else { @() }
            $out = ($secret + "`n" + $script) | & kubectl @KubectlArgs -n procure exec -i $target @containerArgs -- bash -c 'IFS= read -r P; export P; exec bash -s' 2>&1
            @($out | ForEach-Object { "$_" })
        }
        $pg = Invoke-InPod 'postgres-0' '' (Get-Secret 'operator-reader-postgres-password') @'
export PGPASSWORD="$P"
q() { psql -X -q -t -A -h 127.0.0.1 -U operator_reader -d "$1" -c "$2" 2>&1 | head -n 1; }
echo "read=$(q requestsdb 'SELECT count(*) >= 0 FROM purchase_requests')"
echo "insert=$(q requestsdb "INSERT INTO purchase_requests (id) VALUES (gen_random_uuid())")"
echo "create=$(q requestsdb 'CREATE TABLE operator_probe (x int)')"
echo "delete=$(q accessdb 'DELETE FROM system_settings WHERE false')"
echo "keycloakdb=$(q keycloakdb 'SELECT count(*) FROM credential')"
echo "auditdb=$(q auditdb 'SELECT true')"
'@
        $v = @{}; foreach ($line in $pg) { if ($line -match '^(\w+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }
        if ($v.read -eq 't') { Pass 'Postgres: operator_reader reads (requestsdb.purchase_requests)' } else { Fail "Postgres read: '$($v.read)'" }
        foreach ($k in 'insert', 'create', 'delete') {
            if ($v[$k] -match 'read-only transaction|permission denied') { Pass "Postgres: operator_reader cannot $($k.ToUpper()) ($($v[$k] -replace '^ERROR:\s*', ''))" }
            else { Fail "Postgres $($k): '$($v[$k])' (expected a refusal)" }
        }
        # Ruling R1: Keycloak's database (password hashes, OTP seeds, client secrets, realm keys) is not the reader's to open at all.
        if ($v.keycloakdb -match 'permission denied for database') { Pass "Postgres: operator_reader cannot connect to keycloakdb" }
        else { Fail "Postgres keycloakdb as operator_reader: '$($v.keycloakdb)' (expected permission denied for database)" }
        if ($v.auditdb -eq 't') { Pass 'Postgres: operator_reader connects to the other databases (auditdb)' } else { Fail "Postgres auditdb: '$($v.auditdb)'" }

        $mongo = Invoke-InPod 'mongo-0' 'mongo' (Get-Secret 'operator-reader-mongo-password') @'
cat > /tmp/probe.js <<'JS'
const s = db.getSiblingDB('suppliersdb');
let r = 'read=' + (s.getCollectionNames().length >= 0);
try { s.getCollection('operator_probe').insertOne({ x: 1 }); r += ' insert=ALLOWED'; } catch (e) { r += ' insert=refused:' + e.codeName; }
try { db.getSiblingDB('assistantchatdb').getCollection('conversations').deleteMany({ _never: 1 }); r += ' delete=ALLOWED'; } catch (e) { r += ' delete=refused:' + e.codeName; }
print(r);
JS
mongosh --quiet --norc "mongodb://operator_reader:$P@localhost:27017/?authSource=admin&directConnection=true&tls=true&tlsCAFile=/etc/procure-ca/ca.crt" /tmp/probe.js 2>&1 | tail -n 1
rm -f /tmp/probe.js
'@
        $line = ($mongo | Select-Object -Last 1)
        if ($line -match 'read=true' -and $line -match 'insert=refused:Unauthorized' -and $line -match 'delete=refused:Unauthorized') { Pass "MongoDB: operator_reader reads, insertOne and deleteMany refused (Unauthorized)" }
        else { Fail "MongoDB: '$line'" }

        $redis = Invoke-InPod 'deploy/redis' '' (Get-Secret 'operator-reader-redis-password') @'
export REDISCLI_AUTH="$P"
c() { printf '%s=' "$1"; shift; redis-cli --no-auth-warning --user operator_reader "$@" 2>&1 | head -n 1; }
c ping PING; c get GET v2:operator-probe; c scan SCAN 0 COUNT 10; c set SET v2:operator-probe 1; c del DEL v2:operator-probe; c keys KEYS '*'
c flushall FLUSHALL; c config CONFIG GET maxmemory; c debug DEBUG SLEEP 0; c acl ACL LIST; c eval EVAL 'return 1' 0
c ring LRANGE procure:bff:data-protection-keys 0 0; c ringtype TYPE procure:bff:data-protection-keys
c session GET procure:bff:session:operator-probe; c user HGETALL procure:bff:user:operator-probe; c ticket GET procure:bff:switch-ticket:operator-probe
c other GET operator-probe-not-allowed
'@
        $v = @{}; foreach ($line in $redis) { if ($line -match '^(\w+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }
        if ($v.ping -eq 'PONG' -and $v.get -notmatch 'NOPERM' -and $v.scan -notmatch 'NOPERM') { Pass 'Redis: operator_reader may PING, GET (an allowed key family) and SCAN' } else { Fail "Redis reads: ping '$($v.ping)' get '$($v.get)' scan '$($v.scan)'" }
        foreach ($k in 'set', 'del', 'keys', 'flushall', 'config', 'debug', 'acl', 'eval') {
            # DEBUG is refused before the ACL is asked (enable-debug-command is off on the server); either refusal counts.
            if ($v[$k] -match 'NOPERM|DEBUG command not allowed') { Pass "Redis: $($k.ToUpper()) refused ($(($v[$k] -split ' ')[0]))" } else { Fail "Redis $($k.ToUpper()): '$($v[$k])' (expected a refusal)" }
        }
        # Fix round 1 I1: the gateway's Data Protection key ring and its session, user and tenant-switch tickets are not readable (with them
        # a reader could forge a session for any signed-in user); nor is a key outside the allow-list.
        foreach ($k in 'ring', 'ringtype', 'session', 'user', 'ticket', 'other') {
            if ($v[$k] -match 'NOPERM') { Pass "Redis: operator_reader cannot read the gateway's secrets ($($k): NOPERM)" } else { Fail "Redis $($k): '$($v[$k])' (expected NOPERM: the key ring and tickets must stay closed)" }
        }
    }

    # --- 7. Rate limits ------------------------------------------------------------------------------------------------------------
    Write-Step 'Rate limits'
    Select-ProcureCluster $Environment
    $ingresses = @{ pgadmin = 'operator/pgadmin'; mongo = 'operator/mongo-ui'; redis = 'operator/redis-insight'; rabbitmq = 'procure/rabbitmq-management'
        keycloak = 'procure/keycloak'; dashboard = 'observability/aspire-dashboard-direct' }
    foreach ($tool in $Only) {
        $ns, $name = $ingresses[$tool] -split '/'
        $mw = & kubectl @KubectlArgs -n $ns get ingress $name -o jsonpath='{.metadata.annotations.traefik\.ingress\.kubernetes\.io/router\.middlewares}' 2>&1
        if ("$mw" -match 'ratelimit@kubernetescrd') { Pass "$tool's Ingress has a rate-limit middleware" } else { Fail "$tool's Ingress $ns/$name middlewares: '$mw'" }
    }
    if (-not $SkipRateLimit) {
        foreach ($tool in $Only | Where-Object { $_ -ne 'keycloak' }) {
            # Anonymous, cheap requests in parallel (Keycloak's own burst is tests/Test-PublicSurface.ps1 9b).
            $url = "https://$($hostOf[$tool])/" + $(if ($tool -eq 'rabbitmq') { 'api/overview' } else { '' })
            $lines = @('silent', 'parallel', 'parallel-max = 60', 'max-time = 20', 'ssl-no-revoke', 'write-out = "%{http_code}\n"')
            if ($SkipCertificateCheck) { $lines += 'insecure' }
            if ($ResolveTo) { $lines += "resolve = $(ConvertTo-CurlString "$($hostOf[$tool]):443:$ResolveTo")" }
            foreach ($i in 1..$RateLimitBurst) { $lines += "url = $(ConvertTo-CurlString $url)"; $lines += 'output = "nul"' }
            $codes = @(($lines -join "`n") | & $curl --config - 2>$null)
            $limited = @($codes | Where-Object { $_ -eq '429' }).Count
            if ($limited -gt 0) { Pass "$($tool): $limited of $RateLimitBurst parallel requests got 429" } else { Fail "$($tool): no 429 in $RateLimitBurst parallel requests" }
        }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host 'Only the operator logins get in; every check passed.' -ForegroundColor Green
