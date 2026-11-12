#Requires -Version 7.4
<#
.SYNOPSIS
    Proves that bootstrap/add-argocd-admin.ps1 cannot make a demo user an Argo CD admin (plan 08 Task 12c review I1), against the live
    Keycloak of an environment (hosted: through the SSH tunnel).
.DESCRIPTION
    The Keycloak group argocd-admins (realm ops since fix wave ruling R6c) is what gives Argo CD's role:admin, and the script is the path
    a human uses to fill it. Every case below must be refused with the group's members unchanged:
      1. a demo user's e-mail (tom@acme.test; the demo users live in realm procure, so here it would be created): refused as a demo
         domain, and not created;
      2. admin@acme.test as e-mail (its password is published on the demo login page);
      3. an e-mail address as user name (realm ops signs in by private user names only, review m4): refused, nothing created;
      4. the e-mail fallback: a new -UserName with the -Email of an existing ordinary user (a probe made here).
    A positive control then adds a new ordinary probe user (it must land in the group, with the required action Configure OTP) and takes
    it out again with -Remove.
    Probe users are named t12c-probe-<kind>-<random>@example.com, created and deleted by this test (also after a failure); any member the
    group did not have before the test is taken out again. Passwords are random, never printed. -Script runs another copy of the script
    (e.g. the previous version, to see this test fail on it).
#>
[CmdletBinding()]
param(
    [string] $Environment = 'hosted',
    [string] $Script = (Join-Path $PSScriptRoot '..\bootstrap\add-argocd-admin.ps1')
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
Select-ProcureCluster $Environment
Assert-ClusterReachable
$Script = (Resolve-Path $Script).Path

$failures = [System.Collections.Generic.List[string]]::new()
function Pass([string] $message) { Write-Host "  PASS  $message" -ForegroundColor Green }
function Fail([string] $message) { Write-Host "  FAIL  $message" -ForegroundColor Red; $failures.Add($message) }

# kcadm in the Keycloak pod, signed in as the automation client (its secret as stdin's first line) or, on an older cluster, as the bootstrap
# admin from the pod's environment (common.ps1 $KeycloakKcadmSignIn; nothing secret on a command line).
$preamble = $KeycloakKcadmSignIn + "`n" + @'
set -eu
export HOME=/tmp
cfg=$(mktemp /tmp/kcadm-XXXXXX.config)
trap 'rm -f "$cfg"' EXIT
K=/opt/keycloak/bin/kcadm.sh
kc_sign_in "$cfg"
kc() { $K "$@" --config "$cfg" -r ops; }
'@
$kcadmSecret = Get-KeycloakKcadmSecretLine
function Invoke-Kc([string] $body, [string[]] $arguments = @()) {
    $text = ($preamble + "`n" + $body) -replace "`r", ''
    $out = $kcadmSecret | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $text _ @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kcadm failed ($LASTEXITCODE): $(($out | ForEach-Object { "$_" }) -join ' ')" }
    @($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Logging into' })
}
function Get-GroupMembers {
    @(Invoke-Kc @'
GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
[ -n "$GID" ] || { echo "no group argocd-admins" >&2; exit 3; }
kc get "groups/$GID/members" --fields username --format csv --noquotes
'@ | Where-Object { $_ })
}
function Get-UserId([string] $name) {
    "$(Invoke-Kc 'kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes' @($name))".Trim()
}
function New-RandomPassword {
    $bytes = [byte[]]::new(24); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    ConvertTo-SecureString -String ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
}

# Runs the script under test; returns @{ Refused; Output } (refused = threw or failed). The password is a random SecureString.
function Invoke-AddAdmin([hashtable] $arguments) {
    $output = $null; $refused = $false
    try {
        $output = & $Script -Environment $Environment -Password (New-RandomPassword) @arguments *>&1 | ForEach-Object { "$_" }
    } catch {
        $refused = $true
        $output = @($output) + "EXCEPTION: $($_.Exception.Message)"
    }
    @{ Refused = $refused; Output = (@($output) -join "`n") }
}

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$victim = "t12c-probe-victim-$suffix"
$okUser = "t12c-probe-ok-$suffix"
$newTestUser = "t12c-probe-new-$suffix"
$before = @(Get-GroupMembers)
Write-Host "Script under test: $Script"
Write-Host "argocd-admins before: $($before.Count) member(s)."

function Assert-Refused([string] $case, [hashtable] $arguments, [string[]] $reasons = @()) {
    $result = Invoke-AddAdmin $arguments
    $after = @(Get-GroupMembers)
    $added = @($after | Where-Object { $_ -notin $before })
    if ($added.Count -gt 0) {
        Fail "$($case): the user was ADDED to argocd-admins ($($added -join ', '))"
        # Undo at once: a demo user must not stay an Argo CD admin.
        foreach ($name in $added) { Invoke-Kc @'
GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
U=$(kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes)
kc delete "users/$U/groups/$GID"
'@ @($name) | Out-Null }
        return
    }
    if (-not $result.Refused) { Fail "$($case): not refused (no error), although the group is unchanged"; return }
    $missing = @($reasons | Where-Object { $result.Output -notmatch [regex]::Escape($_) })
    if ($missing) { Fail "$($case): refused, but the reason does not name: $($missing -join '; ')"; return }
    Pass "$case refused, group unchanged$(if ($reasons) { " (reasons: $($reasons -join '; '))" })"
}

try {
    # A probe user: an ordinary one (the e-mail fallback's victim).
    Invoke-Kc @'
kc create users -s username="$1" -s email="$1@example.com" -s firstName=Probe -s lastName=Victim -s enabled=true >/dev/null
'@ @($victim) | Out-Null
    Write-Host 'Probe user created (victim).'

    Assert-Refused '1. demo user e-mail tom@acme.test' @{ UserName = $newTestUser; Email = 'tom@acme.test' } @('demo domain')
    if (Get-UserId $newTestUser) { Fail '1. a user with a *.test e-mail was created in realm ops' } else { Pass '1. no user with a *.test e-mail was created' }
    Assert-Refused '2. admin@acme.test as e-mail (published password)' @{ UserName = $newTestUser; Email = 'admin@acme.test' } @('demo domain')
    Assert-Refused '3. an e-mail address as user name' @{ UserName = 'tom@acme.test'; Email = 'x@example.com' } @('UserName')
    if (Get-UserId 'tom@acme.test') { Fail '3. a user named tom@acme.test was created' } else { Pass '3. no user named with an e-mail address was created' }
    Assert-Refused '4. e-mail fallback (a new -UserName with an existing user''s -Email)' @{ UserName = $okUser; Email = "$victim@example.com" } @('identifier mismatch')
    if (Get-UserId $okUser) { Fail '4. a user was created with the other user''s e-mail' } else { Pass '4. no user created for the e-mail fallback' }

    # Positive control: an ordinary new user is added (and removed again).
    $result = Invoke-AddAdmin @{ UserName = $okUser; Email = "$okUser@example.com"; FirstName = 'Probe'; LastName = 'Ok' }
    $after = @(Get-GroupMembers)
    if (-not $result.Refused -and $okUser -in $after) { Pass 'positive control: a new ordinary user is added to argocd-admins' }
    else { Fail "positive control: the ordinary user was not added: $($result.Output)" }
    $actions = "$(Invoke-Kc 'U=$(kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes); kc get "users/$U" --fields requiredActions' @($okUser))"
    if ($actions -match 'CONFIGURE_TOTP') { Pass 'positive control: the new admin must set up an authenticator app (Configure OTP) at the first sign-in' }
    else { Fail "positive control: no Configure OTP required action on the new admin: $actions" }
    $result = Invoke-AddAdmin @{ UserName = $okUser; Remove = $true }
    if (-not $result.Refused -and $okUser -notin (Get-GroupMembers)) { Pass 'positive control: -Remove takes it out again' }
    else { Fail "positive control: -Remove failed: $($result.Output)" }
} finally {
    # Back to the state before the test: probe users deleted, nobody new left in the group.
    $extra = @(Get-GroupMembers | Where-Object { $_ -notin $before })
    foreach ($name in $extra) {
        Invoke-Kc @'
GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
U=$(kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes)
[ -z "$U" ] || kc delete "users/$U/groups/$GID"
'@ @($name) | Out-Null
        Write-Host "Cleanup: took $name out of argocd-admins."
    }
    foreach ($name in $victim, $okUser, $newTestUser) {
        Invoke-Kc 'U=$(kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes); [ -z "$U" ] || kc delete "users/$U"' @($name) | Out-Null
    }
    $now = @(Get-GroupMembers)
    Write-Host "Cleanup: probe users deleted; argocd-admins now has $($now.Count) member(s) ($(if ((($before | Sort-Object) -join ',') -eq (($now | Sort-Object) -join ',')) { 'as before' } else { 'NOT as before' }))."
}

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) FAIL" -ForegroundColor Red; exit 1 }
Write-Host 'All passed.' -ForegroundColor Green
