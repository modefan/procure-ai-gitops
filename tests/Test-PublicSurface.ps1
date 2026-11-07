#Requires -Version 7.4
<#
.SYNOPSIS
    What the hosted demo shows the internet (plan 08 Review Focus 2), checked from outside the VM (Dale's PC).
.DESCRIPTION
    1. DNS (public resolver 1.1.1.1): procure, auth and dashboard.<domain> have an A record to the VM's IPv4 address and no AAAA record
       (the k3s cluster is IPv4-only; plan 08 Task 12 ruling).
    2. Port scan of the VM's IPv4 address (TCP connect; 1-1024, the well-known database, broker, Kubernetes, OTLP and dashboard ports, and
       the whole NodePort range 30000-32767): only 22, 80 and 443 answer. 6443 (Kubernetes API), 4317/4318 (OTLP), 8025 (Mailpit),
       8080 and 18888 are named in the report.
    3. SSH offers only public-key authentication.
    4. http://<host>/ redirects (301/308) to https://<host>/ for every host.
    5. Each host's certificate is issued by Let's Encrypt (production; -AllowStaging accepts the staging CA, "(STAGING)"), valid for the
       host name, verified against Git for Windows' CA bundle with openssl (not .NET: ESET on this PC intercepts TLS from pwsh), and
       valid for at least 14 more days (cert-manager renews 30 days before the end).
    6. Keycloak's public host serves only the procure realm and static resources: /admin, /admin/master/console/, the master realm's
       discovery and token endpoints, the welcome page and /metrics answer 404; the procure realm's discovery answers 200 with issuer
       https://auth.<domain>/realms/procure.
    7. No other site answers on 443: Argo CD and Mailpit host names (hosted and local spellings) and the bare IP give Traefik's 404.
    8. The dashboard redirects to Keycloak's sign-in for client aspire-dashboard, and its telemetry API answers 404.
    9. The app (https://procure.<domain>/) answers 200.
    Nothing secret is used. Exit code 1 on any failure.
.EXAMPLE
    ./tests/Test-PublicSurface.ps1                 # daleabels.com, production certificates
    ./tests/Test-PublicSurface.ps1 -AllowStaging   # while the staging issuer is in use
#>
[CmdletBinding()]
param(
    [string] $Domain = 'daleabels.com',
    [string] $AppHost = "procure.$Domain",
    [string] $KeycloakHost = "auth.$Domain",
    [string] $DashboardHost = "dashboard.$Domain",
    # The VM's IPv4 address; default: host.json of the hosted bootstrap.
    [string] $Ip,
    # Accept certificates from Let's Encrypt's staging CA (before the production issuer is switched on).
    [switch] $AllowStaging,
    # Skip the port scan (about 20 s).
    [switch] $SkipPortScan,
    [int] $PortTimeoutMs = 2500,
    [int] $MinCertDays = 14
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }
function Write-Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }

if (-not $Ip) { $Ip = (Get-HostedHost).ipv4 }
$hosts = @($AppHost, $KeycloakHost, $DashboardHost)
$curl = @("$env:SystemRoot\System32\curl.exe", 'C:\Program Files\Git\mingw64\bin\curl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$openssl = Get-OpenSsl
$caBundle = @('C:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt', 'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $caBundle) { throw "Git for Windows' CA bundle (ca-bundle.crt) not found." }

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-surface-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

function Invoke-Http {
    # One request, no redirect followed, certificate not checked (step 5 checks certificates with openssl). Returns @{ Status; Location;
    # Body }. -Resolve sends the request for $Url's host to the VM's address (also for names without DNS records).
    param([Parameter(Mandatory)] [string] $Url, [string] $Method = 'GET', [switch] $Resolve, [string[]] $Extra = @())
    $bodyFile = Join-Path $work 'body.txt'; $headerFile = Join-Path $work 'headers.txt'
    Remove-Item $bodyFile, $headerFile -ErrorAction SilentlyContinue
    $uri = [Uri] $Url
    $resolveArgs = if ($Resolve) { @('--resolve', "$($uri.Host):$($uri.Port):$Ip") } else { @() }
    $out = & $curl -sS -k --ssl-no-revoke --max-time 20 -X $Method -o $bodyFile -D $headerFile -w '%{http_code}' @resolveArgs @Extra $Url 2>&1
    $status = if ("$out" -match '(\d{3})$') { [int] $Matches[1] } else { 0 }
    $location = Get-Content $headerFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^location:\s*(.+)$' } |
        ForEach-Object { $Matches[1].Trim() } | Select-Object -Last 1
    $body = if (Test-Path $bodyFile) { Get-Content -Raw $bodyFile } else { "$out" }
    [pscustomobject]@{ Status = $status; Location = $location; Body = "$body" }
}

try {
    # --- 1. DNS --------------------------------------------------------------------------------------------------------------------
    Write-Step "DNS (resolver 1.1.1.1)"
    foreach ($h in $hosts) {
        $a = @(Resolve-DnsName $h -Server 1.1.1.1 -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'A' | ForEach-Object IPAddress)
        $aaaa = @(Resolve-DnsName $h -Server 1.1.1.1 -Type AAAA -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'AAAA' | ForEach-Object IPAddress)
        if ($a.Count -eq 1 -and $a[0] -eq $Ip) { Pass "$h A $Ip" } else { Fail "$h A records [$($a -join ', ')], expected exactly $Ip" }
        if ($aaaa.Count -eq 0) { Pass "$h has no AAAA record (IPv4-only cluster)" } else { Fail "$h has AAAA record(s) [$($aaaa -join ', ')]: the cluster serves IPv4 only" }
    }

    # --- 2. Port scan --------------------------------------------------------------------------------------------------------------
    if (-not $SkipPortScan) {
        $named = @{ 22 = 'SSH'; 80 = 'HTTP'; 443 = 'HTTPS'; 2379 = 'etcd'; 4317 = 'OTLP gRPC'; 4318 = 'OTLP HTTP'; 5432 = 'Postgres'
            5672 = 'RabbitMQ'; 6379 = 'Redis'; 6443 = 'Kubernetes API'; 8025 = 'Mailpit'; 8080 = 'Traefik/Argo CD'; 10250 = 'kubelet'
            15672 = 'RabbitMQ management'; 16443 = 'tunnel port'; 18888 = 'Aspire dashboard'; 27017 = 'MongoDB' }
        $ports = [System.Collections.Generic.SortedSet[int]]::new()
        foreach ($p in 1..1024) { [void] $ports.Add($p) }
        foreach ($p in 1080, 1433, 1521, 2049, 2375, 2376, 2379, 2380, 3000, 3306, 3389, 4317, 4318, 4369, 5000, 5432, 5672, 5900, 6379, 6443,
            6444, 7946, 8000, 8008, 8025, 8080, 8081, 8443, 8472, 8888, 9000, 9090, 9093, 9100, 9200, 9300, 9443, 10248, 10249, 10250,
            10251, 10252, 10255, 10256, 10257, 10259, 15672, 16443, 18080, 18888, 25672, 27017, 50000, 51820) { [void] $ports.Add($p) }
        foreach ($p in 30000..32767) { [void] $ports.Add($p) }
        Write-Step "Port scan of $Ip ($($ports.Count) TCP ports, connect with a $PortTimeoutMs ms timeout)"
        $open = [System.Collections.Generic.List[int]]::new()
        $all = @($ports)
        for ($i = 0; $i -lt $all.Count; $i += 512) {
            $batch = @(foreach ($port in $all[$i..([Math]::Min($i + 511, $all.Count - 1))]) {
                    $client = [System.Net.Sockets.TcpClient]::new()
                    [pscustomobject]@{ Port = $port; Client = $client; Task = $client.ConnectAsync($Ip, $port) }
                })
            try { [void] [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]] @($batch.Task), $PortTimeoutMs) } catch { }
            foreach ($b in $batch) {
                if ($b.Task.Status -eq 'RanToCompletion' -and $b.Client.Connected) { $open.Add($b.Port) }
                $b.Client.Dispose()
            }
        }
        $unexpected = @($open | Where-Object { $_ -notin 22, 80, 443 })
        $missing = @(22, 80, 443 | Where-Object { $_ -notin $open })
        if ($unexpected.Count -eq 0 -and $missing.Count -eq 0) { Pass "only 22, 80 and 443 answer of $($ports.Count) ports scanned" }
        foreach ($p in $unexpected) { Fail "port $p answers on $Ip$(if ($named.ContainsKey($p)) { " ($($named[$p]))" })" }
        foreach ($p in $missing) { Fail "port $p ($($named[$p])) does not answer on $Ip" }
        foreach ($p in 6443, 4317, 4318, 8025, 8080, 18888, 10250) { if ($p -notin $open) { Pass "$p ($($named[$p])) does not answer" } }
    }

    # --- 3. SSH: public key only -----------------------------------------------------------------------------------------------------
    Write-Step 'SSH authentication methods'
    $probeUser = 'surface-probe'
    $sshOut = & ssh -o BatchMode=yes -o PreferredAuthentications=none -o "UserKnownHostsFile=$HostedKnownHosts" -o StrictHostKeyChecking=yes `
        -o ConnectTimeout=15 -o IdentitiesOnly=yes -o IdentityAgent=none "$probeUser@$Ip" exit 2>&1 | ForEach-Object { "$_" }
    $methods = ($sshOut | Where-Object { $_ -match 'Permission denied \(([^)]*)\)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
    if ($methods -eq 'publickey') { Pass 'SSH offers only publickey' } else { Fail "SSH offers '$methods' ($(($sshOut | Select-Object -Last 2) -join ' | '))" }

    # --- 4. http redirects to https ------------------------------------------------------------------------------------------------
    Write-Step 'http:// redirects to https://'
    foreach ($h in $hosts) {
        $r = Invoke-Http "http://$h/some/path?x=1"
        if ($r.Status -in 301, 308 -and $r.Location -eq "https://$h/some/path?x=1") { Pass "http://$h/ -> $($r.Status) https://$h/ (path and query kept)" }
        else { Fail "http://$h/some/path?x=1 answered $($r.Status), Location '$($r.Location)' (expected 301/308 to https)" }
    }

    # --- 5. Certificates ---------------------------------------------------------------------------------------------------------------
    Write-Step "Certificates (openssl, CA bundle $caBundle)"
    foreach ($h in $hosts) {
        $text = ('' | & $openssl s_client -connect "${Ip}:443" -servername $h -verify_hostname $h -CAfile $caBundle 2>&1) -join "`n"
        $verified = $text -match 'Verify return code: 0 \(ok\)'
        $issuer = if ($text -match '(?m)^issuer=(.+)$') { $Matches[1].Trim() } else { '' }
        $pem = if ($text -match '(?s)(-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----)') { $Matches[1] } else { $null }
        $staging = $issuer -match '\(STAGING\)'
        $letsEncrypt = $issuer -match "O ?= ?Let's Encrypt"
        if (-not $pem) { Fail "$h presents no certificate: $(($text -split "`n" | Select-Object -Last 3) -join ' | ')"; continue }
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Text.Encoding]::ASCII.GetBytes($pem))
        $days = [int] ($cert.NotAfter - (Get-Date)).TotalDays
        if ($letsEncrypt -and -not $staging -and $verified) { Pass "$h certificate from Let's Encrypt ($issuer), verified for the host name, $days days left" }
        elseif ($letsEncrypt -and $staging -and $AllowStaging) { Pass "$h certificate from Let's Encrypt STAGING ($issuer; accepted with -AllowStaging), $days days left" }
        else { Fail "$h certificate issuer '$issuer', verified for $h by a public CA: $verified (expected Let's Encrypt$(if (-not $AllowStaging) { ' production' }))" }
        if ($days -lt $MinCertDays) { Fail "$h certificate ends $($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days; renewal should keep it above $MinCertDays)" }
    }

    # --- 6. Keycloak: the procure realm and static resources only ---------------------------------------------------------------------
    Write-Step "Keycloak's public paths (https://$KeycloakHost)"
    foreach ($path in '/admin', '/admin/', '/admin/master/console/', '/admin/realms/procure/users', '/realms/master/.well-known/openid-configuration',
        '/realms/master/account', '/', '/metrics', '/health/ready', '/js/keycloak.js') {
        $r = Invoke-Http "https://$KeycloakHost$path"
        if ($r.Status -eq 404) { Pass "$path answers 404" } else { Fail "https://$KeycloakHost$path answered $($r.Status), expected 404 (not a public path)" }
    }
    $r = Invoke-Http "https://$KeycloakHost/realms/master/protocol/openid-connect/token" -Method POST -Extra @('--data', 'grant_type=password&client_id=admin-cli&username=x&password=x')
    if ($r.Status -eq 404) { Pass 'the master realm token endpoint answers 404 (no admin login from outside)' }
    else { Fail "the master realm token endpoint answered $($r.Status), expected 404" }
    $issuer = "https://$KeycloakHost/realms/procure"
    $r = Invoke-Http "$issuer/.well-known/openid-configuration"
    if ($r.Status -eq 200 -and ($r.Body | ConvertFrom-Json).issuer -eq $issuer) { Pass "the procure realm's discovery answers 200, issuer $issuer" }
    else { Fail "the procure realm's discovery answered $($r.Status) $($r.Body.Substring(0, [Math]::Min(200, $r.Body.Length)))" }

    # --- 7. No other site on 443 --------------------------------------------------------------------------------------------------------
    Write-Step 'Nothing else answers on 443 (Argo CD, Mailpit, the bare address)'
    foreach ($h in "argocd.$Domain", "mail.$Domain", "mailpit.$Domain", 'argocd.procure.localtest.me', 'mail.procure.localtest.me') {
        $r = Invoke-Http "https://$h/" -Resolve
        if ($r.Status -eq 404) { Pass "https://$h/ (sent to $Ip) answers 404" } else { Fail "https://$h/ (sent to $Ip) answered $($r.Status), expected 404" }
    }
    $r = Invoke-Http "https://$Ip/"
    if ($r.Status -eq 404) { Pass "https://$Ip/ (no host name) answers 404" } else { Fail "https://$Ip/ answered $($r.Status), expected 404" }

    # --- 8. The dashboard needs a Keycloak sign-in -------------------------------------------------------------------------------------
    Write-Step "The dashboard (https://$DashboardHost)"
    $url = "https://$DashboardHost/"; $r = $null
    foreach ($hop in 1..3) {
        $r = Invoke-Http $url
        if ($r.Status -ne 302 -or -not $r.Location) { break }
        $next = if ($r.Location.StartsWith('/')) { "https://$DashboardHost$($r.Location)" } else { $r.Location }
        if (-not $next.StartsWith("https://$DashboardHost/")) { break }
        $url = $next
    }
    if ($r.Status -eq 302 -and $r.Location -and $r.Location.StartsWith("https://$KeycloakHost/realms/procure/protocol/openid-connect/auth?") -and
        $r.Location.Contains('client_id=aspire-dashboard')) { Pass "https://$DashboardHost/ redirects to Keycloak's sign-in (client aspire-dashboard)" }
    else { Fail "https://$DashboardHost/ ended with $($r.Status) at $url, Location '$($r.Location)' (expected a Keycloak sign-in)" }
    foreach ($path in '/api/telemetry/logs', '/api/telemetry/traces') {
        $r = Invoke-Http "https://$DashboardHost$path"
        if ($r.Status -eq 404) { Pass "$path answers 404 (dashboard API off)" } else { Fail "https://$DashboardHost$path answered $($r.Status), expected 404" }
    }

    # --- 9. The app ---------------------------------------------------------------------------------------------------------------------
    Write-Step "The app (https://$AppHost)"
    $r = Invoke-Http "https://$AppHost/"
    if ($r.Status -eq 200) { Pass "https://$AppHost/ answers 200" } else { Fail "https://$AppHost/ answered $($r.Status)" }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) public-surface check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nThe public surface is what it should be." -ForegroundColor Green
exit 0
