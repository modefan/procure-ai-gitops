#Requires -Version 7.4
<#
.SYNOPSIS
    Dale's sign-in to one of the operator's tools (plan 08b Task 4): prints the address and user name, copies the password to the
    clipboard and prints the current one-time code where the tool asks for one. Never prints a password or a TOTP secret.
.DESCRIPTION
    Reads DEMO PASSWORDS.txt on the Desktop (CLAUDE.md "Secrets"), the section bootstrap/new-secrets.ps1 keeps for the environment:
      hosted  "=== procure-ai hosted (Contabo) secrets"        lines "<name>: <value>"
      local   "=== procure-ai local: all AppHost user secrets"  lines "Parameters:<name>: <value>"
    Every operator login is a generated value there (names operator-*; new-secrets.ps1 writes them, never by hand), so a rotated value is
    picked up at once. The one-time code (RFC 6238: SHA-1, 6 digits, 30 s) is computed from the Base32 secret of the same section; it is
    valid for the seconds the script prints.

    Tool           address (hosted)                                   user name                 password entry                 code
    pgadmin        https://pgadmin.daleabels.com                      operator@daleabels.com    operator-pgadmin-password      operator-pgadmin-totp-base32
    mongo          https://mongo.daleabels.com (DbGate)               operator                  operator-mongo-ui-password
    redis          https://redis.daleabels.com (Redis Insight)        operator                  operator-redis-insight-password
    rabbitmq       https://rabbitmq.daleabels.com                     operator                  operator-rabbitmq-password
    keycloak       https://auth.daleabels.com/admin/master/console/   operator                  operator-keycloak-password     operator-keycloak-totp-base32
    dashboard      https://dashboard-direct.daleabels.com             operator                  operator-dashboard-token
    Inside a tool, for an emergency write (the tools connect read-only by default):
    postgres-admin superuser `postgres` in pgAdmin's "superuser (emergency)" server      postgres-password
    mongo-admin    root user in DbGate's "root (emergency)" connection                  mongo-password (user: mongo-username, default admin)
    redis-admin    Redis's default user (add a connection in Redis Insight)             redis-password
.EXAMPLE
    ./bootstrap/hosted/Get-OperatorLogin.ps1 -Tool pgadmin
    ./bootstrap/hosted/Get-OperatorLogin.ps1 -Tool keycloak -Environment local -NoClipboard
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('pgadmin', 'mongo', 'redis', 'rabbitmq', 'keycloak', 'dashboard', 'postgres-admin', 'mongo-admin', 'redis-admin')]
    [string] $Tool,
    [ValidateSet('hosted', 'local')]
    [string] $Environment = 'hosted',
    # Do not touch the clipboard (the password is then not shown anywhere: look it up in DEMO PASSWORDS.txt by the printed entry name).
    [switch] $NoClipboard,
    [string] $Path
)

. (Join-Path $PSScriptRoot '..\common.ps1')
if (-not $Path) { $Path = $DemoPasswordsFile }

$hosted = $Environment -eq 'hosted'
$entries = Read-OperatorSecrets -Environment $Environment -Path $Path
$domain = if ($hosted) { $HostedDomain } else { 'procure.localtest.me' }

$tools = @{
    'pgadmin'        = @{ Url = "https://pgadmin.$domain"; User = "operator@$(if ($hosted) { $domain } else { 'procure.localtest.me' })"; Password = 'operator-pgadmin-password'; Totp = 'operator-pgadmin-totp-base32' }
    'mongo'          = @{ Url = "https://mongo.$domain"; User = 'operator'; Password = 'operator-mongo-ui-password' }
    'redis'          = @{ Url = "https://redis.$domain"; User = 'operator'; Password = 'operator-redis-insight-password' }
    'rabbitmq'       = @{ Url = "https://rabbitmq.$domain"; User = 'operator'; Password = 'operator-rabbitmq-password' }
    'keycloak'       = @{ Url = "https://auth.$domain/admin/master/console/"; User = 'operator'; Password = 'operator-keycloak-password'; Totp = 'operator-keycloak-totp-base32' }
    'dashboard'      = @{ Url = "https://dashboard-direct.$domain"; User = 'operator'; Password = 'operator-dashboard-token' }
    'postgres-admin' = @{ Url = "https://pgadmin.$domain (server 'procure (superuser, emergency)')"; User = 'postgres'; Password = 'postgres-password' }
    'mongo-admin'    = @{ Url = "https://mongo.$domain (connection 'procure MongoDB root (emergency)')"; User = ($entries['mongo-username'] ?? 'admin'); Password = 'mongo-password' }
    'redis-admin'    = @{ Url = "https://redis.$domain (add a connection: host redis.procure.svc.cluster.local, port 6379)"; User = 'default'; Password = 'redis-password' }
}
$t = $tools[$Tool]
$password = $entries[$t.Password]
if ([string]::IsNullOrEmpty($password)) { throw "No entry '$($t.Password)' in DEMO PASSWORDS.txt (run bootstrap/new-secrets.ps1$(if ($hosted) { ' -Environment hosted' }))." }

Write-Host "$Tool ($Environment)"
Write-Host "  Address:   $($t.Url)"
Write-Host "  User name: $($t.User)"
if ($NoClipboard) {
    Write-Host "  Password:  DEMO PASSWORDS.txt, entry '$($t.Password)' (not copied: -NoClipboard)"
} else {
    Set-Clipboard -Value $password
    Write-Host "  Password:  copied to the clipboard (DEMO PASSWORDS.txt, entry '$($t.Password)'); clear it with Set-Clipboard -Value ' '"
}
if ($t['Totp']) {
    $secret = $entries[$t['Totp']]
    if ([string]::IsNullOrEmpty($secret)) { throw "No entry '$($t['Totp'])' in DEMO PASSWORDS.txt." }
    # The server's clock, not this PC's (which can be off by more than a 30-second step).
    $offset = Get-ServerClockOffset (($t.Url -split ' ')[0])
    if ($null -eq $offset) { $offset = Get-ServerClockOffset "https://$(if ($hosted) { "procure.$domain" } else { $domain })/" }
    if ($null -eq $offset) { Write-Host "  (no server answered for the time: the code uses this PC's clock)"; $offset = 0 }
    $code = Get-TotpCode $secret -OffsetSeconds $offset
    if ([Math]::Abs($offset) -ge 5) { Write-Host "  (this PC's clock is $(-$offset) s off the server's; the code uses the server's time)" }
    Write-Host "  Code:      $($code.Code)  (valid $($code.SecondsLeft) more seconds; run again for the next one)"
}
