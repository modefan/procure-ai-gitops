#Requires -Version 7.4
<#
.SYNOPSIS
    Generates an API token for Argo CD's local account `claude` (apiKey only, role:admin; argocd/values.yaml) and puts it in the user env
    var ARGOCD_AUTH_TOKEN_<ENVIRONMENT> (ARGOCD_AUTH_TOKEN_HOSTED, ARGOCD_AUTH_TOKEN_LOCAL). Never prints it.
.DESCRIPTION
    Claude must be able to do every Argo CD admin function without Keycloak (CLAUDE.md "Hosting plan", 2026-11-08). The token is what it
    uses: `Authorization: Bearer $env:ARGOCD_AUTH_TOKEN_HOSTED` on Argo CD's REST API (or the argocd CLI, which reads ARGOCD_AUTH_TOKEN).
    How: a temporary `kubectl port-forward` of argocd-server to a free loopback port (plain http behind it, no TLS to intercept), a session
    for the admin user (password from Secret argocd/argocd-initial-admin-secret, read in memory only), then
    POST /api/v1/account/claude/token. The token does not expire (-ExpiresInDays to change that); it is revoked by its ID
    (DELETE /api/v1/account/claude/token/<id>, or -RevokeOthers on the next run). The script also writes the token into DEMO
    PASSWORDS.txt itself (section "=== Argo CD", line "<Hosted|Local> claude API token ...", replaced when it exists; review 12c N6),
    printing only the line's name.
    Needs the admin login on (argocd.adminEnabled, both environments since Task 12c) and, for hosted, the SSH tunnel (opened when needed).
#>
[CmdletBinding()]
param(
    # The folder under envs/: 'hosted' is the VM, anything else the local k3d cluster.
    [string] $Environment = 'local',
    # 0: no expiry.
    [int] $ExpiresInDays = 0,
    # Revoke every other token of `claude` once the new one works.
    [switch] $RevokeOthers
)

. (Join-Path $PSScriptRoot 'common.ps1')
Select-ProcureCluster $Environment
Assert-ClusterReachable
$envVar = "ARGOCD_AUTH_TOKEN_$($Environment.ToUpperInvariant())"

$b64 = Invoke-Kubectl -n argocd get secret argocd-initial-admin-secret -o 'jsonpath={.data.password}'
if ([string]::IsNullOrWhiteSpace("$b64")) { throw 'Secret argocd/argocd-initial-admin-secret has no password (deleted?). Generate the token while signed in as an admin instead.' }
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$b64".Trim()))

# A free loopback port for the port-forward.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$base = "http://127.0.0.1:$port"
$forwardArgs = @($KubectlArgs) + @('-n', 'argocd', 'port-forward', '--address', '127.0.0.1', 'svc/argocd-server', "$($port):80")
$quoted = $forwardArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$forward = Start-Process -FilePath (Get-Command kubectl).Source -ArgumentList $quoted -WindowStyle Hidden -PassThru
try {
    $deadline = (Get-Date).AddSeconds(30)
    while ($true) {
        try { if ((Invoke-WebRequest "$base/healthz" -TimeoutSec 3 -SkipHttpErrorCheck).StatusCode -eq 200) { break } } catch { }
        if ($forward.HasExited -or (Get-Date) -gt $deadline) { throw 'The port-forward to argocd-server did not answer within 30 s.' }
        Start-Sleep -Milliseconds 500
    }

    $session = (Invoke-RestMethod -Method Post "$base/api/v1/session" -ContentType 'application/json' `
            -Body (@{ username = 'admin'; password = $adminPassword } | ConvertTo-Json)).token
    $adminPassword = $null
    $headers = @{ Authorization = "Bearer $session" }

    $id = "claude-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $body = @{ id = $id; expiresIn = [long] $ExpiresInDays * 86400 } | ConvertTo-Json
    $token = (Invoke-RestMethod -Method Post "$base/api/v1/account/claude/token" -Headers $headers -ContentType 'application/json' -Body $body).token

    # The new token must work before it replaces the old one: list the Applications with it.
    $apps = Invoke-RestMethod "$base/api/v1/applications?fields=items.metadata.name" -Headers @{ Authorization = "Bearer $token" }
    $names = @($apps.items | ForEach-Object { $_.metadata.name })
    if ($names.Count -eq 0) { throw "The new token $id lists no Applications (is account claude bound to role:admin in argocd-rbac-cm?). Not stored." }

    [Environment]::SetEnvironmentVariable($envVar, $token, 'User')
    Set-Item "env:$envVar" $token
    $envLabel = if ($Environment -eq 'hosted') { 'Hosted' } else { 'Local' }
    $key = "$envLabel claude API token"
    $expiry = if ($ExpiresInDays -gt 0) { "expires in $ExpiresInDays days" } else { 'no expiry' }
    Set-DemoPasswordEntry -Section 'Argo CD' -Key $key -Value $token `
        -Label "$key (account claude, apiKey only, role:admin; token id $id, $expiry; user env var $envVar; new one: bootstrap/new-argocd-token.ps1 -Environment $Environment)"
    $token = $null
    Write-Host "Token $id for account claude stored in user env var $envVar and in DEMO PASSWORDS.txt (section Argo CD, line '$key ...'); it sees $($names.Count) Applications: $($names -join ', ')."

    $account = Invoke-RestMethod "$base/api/v1/account/claude" -Headers $headers
    $others = @($account.tokens | Where-Object { $_.id -ne $id })
    if ($RevokeOthers) {
        foreach ($other in $others) {
            Invoke-RestMethod -Method Delete "$base/api/v1/account/claude/token/$($other.id)" -Headers $headers | Out-Null
            Write-Host "Revoked token $($other.id)."
        }
    } elseif ($others.Count -gt 0) {
        Write-Host "Other tokens of claude still valid: $(($others | ForEach-Object { $_.id }) -join ', ') (-RevokeOthers revokes them)."
    }
} finally {
    if (-not $forward.HasExited) { Stop-Process -Id $forward.Id -ErrorAction SilentlyContinue }
}
