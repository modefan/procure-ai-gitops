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

    The Keycloak gate of the public Argo CD host (plan 08c Task 1, rulings R2 and R9; hosted only, -SkipGate leaves it out), signed in the
    way a browser does (curl with a cookie jar, every redirect followed by hand; the one-time code computed from the secret Keycloak's
    "Configure OTP" page shows, with the server's clock):
      5. a probe user in argocd-admins: Argo CD's address sends it to realm ops' sign-in (client argocd-gate); password, then setting up an
         authenticator app and its code; the gate lets it in: Argo CD's page (200, "Argo CD"), and Argo CD's own "Log in via Keycloak"
         finishes without another password (same Keycloak session) and lists the Applications (root among them);
      6. that same signed-in user still gets 403 for POST /api/v1/session (the username/password login; R2) and Argo CD never answers it;
      7. a probe user of realm ops NOT in argocd-admins: password and code accepted by Keycloak, then 403 from the gate, and Argo CD's
         address still sends it to the sign-in (no gate session);
      8. a demo user of realm procure (-DemoUser, its real password from Secret procure-keycloak demo-password): realm ops' sign-in refuses
         it ("Invalid username or password"), no one-time code step, no way on to Argo CD.
    Probe users t08c-probe-<kind>-<random> are made with kcadm and deleted afterwards (also after a failure); their passwords are random.
#>
[CmdletBinding()]
param(
    [string] $Environment = 'hosted',
    [string] $Script = (Join-Path $PSScriptRoot '..\bootstrap\add-argocd-admin.ps1'),
    # The public Argo CD host behind the Keycloak gate (steps 5-8).
    [string] $GateUrl = 'https://argocd.daleabels.com',
    # Realm ops' address (the gate's identity provider).
    [string] $OpsRealmUrl = 'https://auth.daleabels.com/realms/ops/',
    # A user of the demo realm (step 8). Its password is the demo password (Secret procure-keycloak, key demo-password).
    [string] $DemoUser = 'tom@acme.test',
    # Leave out steps 5-8 (the local cluster has no gate).
    [switch] $SkipGate,
    # Only steps 5-8.
    [switch] $GateOnly
)
if ($Environment -ne 'hosted') { $SkipGate = $true }
if ($GateOnly -and $SkipGate) { throw '-GateOnly needs the hosted gate (and no -SkipGate).' }

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
$script:KcSignIn = ''
function Invoke-Kc([string] $body, [string[]] $arguments = @()) {
    $text = ($preamble + "`n" + $body) -replace "`r", ''
    $out = $kcadmSecret | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $text _ @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kcadm failed ($LASTEXITCODE): $(($out | ForEach-Object { "$_" }) -join ' ')" }
    $lines = @($out | ForEach-Object { "$_" })
    # kc_sign_in's 'kcadm: ...' line names the identity used (review m9); kept apart from the command's output.
    $script:KcSignIn = "$($lines | Where-Object { $_ -match '^kcadm: ' } | Select-Object -Last 1)"
    @($lines | Where-Object { $_ -notmatch '^Logging into' -and $_ -notmatch '^kcadm: ' })
}

# Review m9: when Secret procure-keycloak has automation-client-secret, the client must be what signs in. A silent fallback to the bootstrap
# admin (still enabled until the first sync with automationClient, or after a rollback) would make this test prove nothing about the client
# (docs/hosting.md uses it as that proof), so it fails before any probe is made.
$null = Invoke-Kc 'true'
Write-Host "Keycloak admin sign-in: $($script:KcSignIn)"
if ($kcadmSecret -and $script:KcSignIn -ne 'kcadm: signed in as client procure-automation') {
    Write-Host '  FAIL  Secret procure-keycloak has automation-client-secret, but kcadm did not sign in as client procure-automation' -ForegroundColor Red
    Write-Host '1 FAIL' -ForegroundColor Red
    exit 1
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

# --- The gate (steps 5-8): a browser's sign-in, by hand. ---
$gateMember = "t08c-probe-member-$suffix"
$gateOutsider = "t08c-probe-outsider-$suffix"
$curl = @("$env:SystemRoot\System32\curl.exe", 'C:\Program Files\Git\mingw64\bin\curl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$work = Join-Path ([IO.Path]::GetTempPath()) ('procure-gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-ProbePassword {
    # Letters and digits only (no quoting trouble in a form body); 32 characters. Never printed.
    [Security.Cryptography.RandomNumberGenerator]::GetString([char[]] 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', 32)
}
function New-GateProbeUser([string] $name, [string] $password, [switch] $Member) {
    # A realm ops user as add-argocd-admin.ps1 makes one (e-mail verified, Configure OTP required), with a password; in argocd-admins with
    # -Member. The password goes to kcadm on stdin (second line), never on a command line.
    $credential = @{ type = 'password'; value = $password; temporary = $false } | ConvertTo-Json -Compress
    $body = @'
IFS= read -r CRED || true
CRED=${CRED%$'\r'}
U=$(kc create users -s username="$1" -s email="$1@example.com" -s firstName=Probe -s lastName=Gate -s enabled=true -s emailVerified=true -s 'requiredActions=["CONFIGURE_TOTP"]' -i)
printf '%s' "$CRED" | kc update "users/$U/reset-password" -f -
if [ "$2" = member ]; then
  GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
  kc update "users/$U/groups/$GID" -s realm=ops -s userId="$U" -s groupId="$GID" -n
fi
'@
    $text = ($preamble + "`n" + $body) -replace "`r", ''
    $out = ($kcadmSecret + "`n" + $credential) | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $text _ $name $(if ($Member) { 'member' } else { 'outsider' }) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "creating probe user $name failed: $(($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Logging into' }) -join ' ')" }
}
function ConvertTo-Base32([byte[]] $bytes) {
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = -join ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') })
    $bits = $bits.PadRight([Math]::Ceiling($bits.Length / 5) * 5, '0')
    -join (0..($bits.Length / 5 - 1) | ForEach-Object { $alphabet[[Convert]::ToInt32($bits.Substring($_ * 5, 5), 2)] })
}
function Invoke-Browser([string] $jar, [string] $url, [string] $method = 'GET', [string[]] $form = @(), [string[]] $headers = @(), [string] $json = '') {
    # One request with the cookie jar; no redirect followed. @{ Status; Location (absolute); Body }.
    $bodyFile = Join-Path $work 'body.html'; $headerFile = Join-Path $work 'headers.txt'
    Remove-Item $bodyFile, $headerFile -ErrorAction SilentlyContinue
    $extra = @()
    foreach ($f in $form) { $extra += @('--data-urlencode', $f) }
    if ($json) { $extra += @('-H', 'Content-Type: application/json', '--data-binary', $json) }
    foreach ($h in $headers) { $extra += @('-H', $h) }
    if (-not ($headers | Where-Object { $_ -like 'Accept:*' })) { $extra += @('-H', 'Accept: text/html,application/xhtml+xml') }
    $out = & $curl -sS -k --ssl-no-revoke --max-time 30 -b $jar -c $jar -X $method -o $bodyFile -D $headerFile -w '%{http_code}' @extra $url 2>&1
    $status = if ("$out" -match '(\d{3})$') { [int] $Matches[1] } else { 0 }
    $location = Get-Content $headerFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^location:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -Last 1
    if ($location -and -not ($location -match '^https?://')) { $location = [Uri]::new([Uri] $url, $location).AbsoluteUri }
    [pscustomobject]@{ Status = $status; Location = $location; Body = $(if (Test-Path $bodyFile) { Get-Content -Raw $bodyFile } else { '' }) }
}
function Get-FormAction([string] $html, [string] $formId) {
    if ($html -notmatch "<form[^>]*id=`"$formId`"[^>]*>") { return $null }
    if ($Matches[0] -notmatch 'action="([^"]+)"') { return $null }
    [Net.WebUtility]::HtmlDecode($Matches[1])
}
function Invoke-Follow([string] $jar, $response, [int] $max = 8) {
    # Follows 30x redirects (GET) until a non-redirect answer.
    $r = $response
    for ($i = 0; $i -lt $max -and $r.Status -in 301, 302, 303, 307, 308 -and $r.Location; $i++) { $r = Invoke-Browser $jar $r.Location }
    $r
}
function Invoke-GateSignIn([string] $jar, [string] $user, [string] $password, [int] $clockOffset) {
    # Argo CD's address -> realm ops' sign-in -> password -> Configure OTP (a new user) or the code -> back to the gate. Returns the gate's
    # answer to Keycloak's redirect back (the /oauth2/callback request) and what happened on the way, as @{ Steps; Callback; LoginPage }.
    $steps = [System.Collections.Generic.List[string]]::new()
    $r = Invoke-Browser $jar "$GateUrl/applications"
    $steps.Add("GET /applications -> $($r.Status)")
    if ($r.Status -ne 302 -or -not "$($r.Location)".StartsWith($OpsRealmUrl)) {
        return @{ Steps = $steps; Callback = $null; LoginPage = $null; Error = "Argo CD's address did not send the browser to realm ops' sign-in (status $($r.Status), Location '$($r.Location)')" }
    }
    $clientId = if ($r.Location -match '[?&]client_id=([^&]+)') { $Matches[1] } else { '' }
    $steps.Add("-> realm ops sign-in (client_id=$clientId)")
    $page = Invoke-Follow $jar (Invoke-Browser $jar $r.Location)
    $action = Get-FormAction $page.Body 'kc-form-login'
    if (-not $action) { return @{ Steps = $steps; Callback = $null; LoginPage = $page; Error = "no sign-in form (status $($page.Status))"; ClientId = $clientId } }
    $r = Invoke-Browser $jar $action 'POST' @("username=$user", "password=$password", 'credentialId=')
    $steps.Add("POST password -> $($r.Status)")
    # Keycloak may answer with a redirect to its own required-action or next-step page first.
    while ($r.Status -in 302, 303 -and "$($r.Location)".StartsWith($OpsRealmUrl)) {
        $steps.Add("-> $(([Uri] $r.Location).AbsolutePath)")
        $r = Invoke-Browser $jar $r.Location
    }
    if ($r.Status -eq 200) {
        $totpAction = Get-FormAction $r.Body 'kc-totp-settings-form'
        $otpAction = Get-FormAction $r.Body 'kc-otp-login-form'
        if ($totpAction -and $r.Body -match 'name="totpSecret"[^>]*value="([^"]+)"|value="([^"]+)"[^>]*name="totpSecret"') {
            # Keycloak keys the code with the bytes of this text (an authenticator app scans the same as Base32).
            $secret = [Net.WebUtility]::HtmlDecode($(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }))
            $code = Get-TotpCode (ConvertTo-Base32 ([Text.Encoding]::UTF8.GetBytes($secret))) -OffsetSeconds $clockOffset
            if ($code.SecondsLeft -lt 4) { Start-Sleep -Seconds ($code.SecondsLeft + 1); $code = Get-TotpCode (ConvertTo-Base32 ([Text.Encoding]::UTF8.GetBytes($secret))) -OffsetSeconds $clockOffset }
            $r = Invoke-Browser $jar $totpAction 'POST' @("totp=$($code.Code)", "totpSecret=$secret", 'userLabel=probe', 'logout-sessions=off')
            $steps.Add("POST Configure OTP code -> $($r.Status)")
        } elseif ($otpAction) {
            return @{ Steps = $steps; Callback = $null; LoginPage = $r; Error = 'one-time code asked for, but this probe has no authenticator'; ClientId = $clientId }
        } else {
            return @{ Steps = $steps; Callback = $null; LoginPage = $r; Error = 'password not accepted (sign-in page again)'; ClientId = $clientId }
        }
    }
    if ($r.Status -notin 302, 303 -or -not $r.Location) { return @{ Steps = $steps; Callback = $null; LoginPage = $r; Error = "Keycloak did not redirect back (status $($r.Status))"; ClientId = $clientId } }
    $steps.Add("-> $(([Uri] $r.Location).AbsolutePath)")
    $callback = Invoke-Browser $jar $r.Location
    $steps.Add("gate callback -> $($callback.Status)")
    @{ Steps = $steps; Callback = $callback; LoginPage = $null; Error = $null; ClientId = $clientId }
}
function Test-NoArgoContent([string] $body) {
    # An Argo CD page or API answer: its UI's title, or JSON with Argo CD's list/version fields.
    $body -notmatch '<title>Argo CD</title>|"Version"\s*:|"items"\s*:|"metadata"\s*:'
}

try {
    if (-not $GateOnly) {
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
    }

    if (-not $SkipGate) {
        Write-Host "The Keycloak gate of $GateUrl (steps 5-8):"
        New-Item -ItemType Directory -Path $work | Out-Null
        $offset = Get-ServerClockOffset "$($OpsRealmUrl.TrimEnd('/'))/.well-known/openid-configuration"
        if ($null -eq $offset) { $offset = 0 }
        $memberPassword = New-ProbePassword
        $outsiderPassword = New-ProbePassword
        New-GateProbeUser $gateMember $memberPassword -Member
        New-GateProbeUser $gateOutsider $outsiderPassword
        Write-Host 'Probe users created (member of argocd-admins, outsider).'

        # 5. A member: through the gate, then Argo CD's own sign-in without another password, and the Applications.
        $jar = Join-Path $work 'member.jar'
        $signIn = Invoke-GateSignIn $jar $gateMember $memberPassword $offset
        Write-Host "    member: $($signIn.Steps -join '; ')"
        if ($signIn.Error) { Fail "5. member: $($signIn.Error)" }
        elseif ($signIn.ClientId -ne 'argocd-gate') { Fail "5. member: the sign-in was for client '$($signIn.ClientId)', expected argocd-gate" }
        elseif ($signIn.Callback.Status -notin 302, 303) { Fail "5. member: the gate answered the callback with $($signIn.Callback.Status), expected a redirect into Argo CD" }
        else {
            $page = Invoke-Follow $jar $signIn.Callback
            if ($page.Status -eq 200 -and $page.Body -match '<title>Argo CD</title>') { Pass "5. member: password + authenticator code, the gate lets it in: Argo CD's page (client argocd-gate)" }
            else { Fail "5. member: after the gate, Argo CD's page answered $($page.Status) (no Argo CD title)" }
            # Argo CD's "Log in via Keycloak": /auth/login -> Keycloak (client argocd; the session from the gate's sign-in) -> /auth/callback.
            $login = Invoke-Browser $jar "$GateUrl/auth/login?return_url=$([Uri]::EscapeDataString("$GateUrl/applications"))"
            $argoClient = if ($login.Location -match '[?&]client_id=([^&]+)') { $Matches[1] } else { '' }
            $after = Invoke-Follow $jar $login
            $apps = Invoke-Browser $jar "$GateUrl/api/v1/applications" -headers @('Accept: application/json')
            $names = @()
            try { $names = @(($apps.Body | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name }) } catch { }
            if ($argoClient -eq 'argocd' -and $apps.Status -eq 200 -and 'root' -in $names) {
                Pass "5. member: Argo CD's Keycloak sign-in needs no second password (same session) and lists $($names.Count) Applications ($($names -join ', '))"
            } else { Fail "5. member: Argo CD's sign-in (client '$argoClient', ended $($after.Status)) and GET /api/v1/applications ($($apps.Status)) did not list the Applications" }

            # 6. The username/password login stays closed, also with a valid gate session.
            $session = Invoke-Browser $jar "$GateUrl/api/v1/session" 'POST' -headers @('Accept: application/json') -json '{"username":"admin","password":"not-the-password"}'
            if ($session.Status -eq 403 -and (Test-NoArgoContent $session.Body)) { Pass '6. POST /api/v1/session with a valid gate session: 403 from the edge (Argo CD never sees it)' }
            else { Fail "6. POST /api/v1/session with a valid gate session answered $($session.Status): $($session.Body.Substring(0, [Math]::Min(160, $session.Body.Length)))" }
            $grpc = Invoke-Browser $jar "$GateUrl/session.SessionService/Create" 'POST' -headers @('Content-Type: application/grpc-web+proto', 'Accept: application/grpc-web+proto')
            if ($grpc.Status -eq 403) { Pass '6. the gRPC-web session create with a valid gate session: 403' } else { Fail "6. POST /session.SessionService/Create answered $($grpc.Status), expected 403" }
        }

        # 7. Signed in to realm ops, but not in argocd-admins: 403 at the gate, no gate session.
        $jar = Join-Path $work 'outsider.jar'
        $signIn = Invoke-GateSignIn $jar $gateOutsider $outsiderPassword $offset
        Write-Host "    outsider: $($signIn.Steps -join '; ')"
        if ($signIn.Error) { Fail "7. outsider: $($signIn.Error)" }
        elseif ($signIn.Callback.Status -eq 403 -and (Test-NoArgoContent $signIn.Callback.Body)) {
            $again = Invoke-Browser $jar "$GateUrl/applications"
            if ($again.Status -eq 302 -and "$($again.Location)".StartsWith($OpsRealmUrl)) { Pass '7. outsider: password and code accepted by Keycloak, then 403 from the gate; Argo CD still sends it to the sign-in' }
            else { Fail "7. outsider: after the 403, Argo CD's address answered $($again.Status) (expected the sign-in redirect, no gate session)" }
        } else { Fail "7. outsider: the gate answered the callback with $($signIn.Callback.Status), expected 403 without Argo CD content" }

        # 8. A demo user of realm procure is unknown to realm ops.
        $encoded = & kubectl @KubectlArgs -n procure get secret procure-keycloak -o 'jsonpath={.data.demo-password}' 2>$null
        $demoPassword = if ($encoded) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$encoded".Trim())) } else { New-ProbePassword }
        $jar = Join-Path $work 'demo.jar'
        $signIn = Invoke-GateSignIn $jar $DemoUser $demoPassword $offset
        $demoPassword = $null
        Write-Host "    demo user: $($signIn.Steps -join '; ')"
        if ($signIn.Error -eq 'password not accepted (sign-in page again)' -and $signIn.LoginPage.Body -match 'Invalid username or password') {
            Pass "8. demo user $DemoUser (demo password): realm ops' sign-in refuses it, no one-time code step, no way on to Argo CD"
        } else { Fail "8. demo user $DemoUser`: expected realm ops to refuse the sign-in, got: $($signIn.Error) / callback $($signIn.Callback.Status)" }
    }
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
    foreach ($name in $victim, $okUser, $newTestUser, $gateMember, $gateOutsider) {
        Invoke-Kc 'U=$(kc get users -q exact=true -q username="$1" --fields id --format csv --noquotes); [ -z "$U" ] || kc delete "users/$U"' @($name) | Out-Null
    }
    $now = @(Get-GroupMembers)
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Write-Host "Cleanup: probe users deleted; argocd-admins now has $($now.Count) member(s) ($(if ((($before | Sort-Object) -join ',') -eq (($now | Sort-Object) -join ',')) { 'as before' } else { 'NOT as before' }))."
}

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) FAIL" -ForegroundColor Red; exit 1 }
Write-Host 'All passed.' -ForegroundColor Green
