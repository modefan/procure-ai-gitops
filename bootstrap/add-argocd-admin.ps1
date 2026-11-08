#Requires -Version 7.4
<#
.SYNOPSIS
    Gives a person's own Keycloak user Argo CD's admin role: creates the user in realm ops when it does not exist (password asked for
    here, never shown or stored), and puts it in the group argocd-admins (plan 08 Task 12c; realm ops since fix wave ruling R6c).
    Realm ops is Argo CD's directory only: not the public demo realm `procure` (shared demo users, no lockout), but its own realm with
    brute-force lockout and an authenticator app (OTP) required for every user; no demo user and no service of the app exists there.
.DESCRIPTION
    For Dale's own user (CLAUDE.md "Hosting plan": he picks the user name and password himself; Claude does not create it). Keycloak's
    admin console is not reachable on the hosted VM (the public host serves /realms/procure/ and /realms/ops/ only, and the console always
    sends the browser to that public host), so this script uses Keycloak's own admin CLI (kcadm.sh) inside the Keycloak pod, through the SSH tunnel:
      - signs in to the master realm as the bootstrap admin from the pod's own environment (KC_CLI_PASSWORD, so no admin password leaves
        the cluster or appears on a command line),
      - creates the user (enabled, e-mail verified) and sets its password, which goes to the pod on kubectl's stdin and to Keycloak on
        kcadm's stdin (never on a command line),
      - makes sure the user must set up an authenticator app at the next sign-in (required action Configure OTP) unless it already has
        one; from then on every sign-in asks for the 6-digit code,
      - adds it to argocd-admins and prints the group's members (names only).
    Realm ops signs in by user name only (registrationEmailAsUsername and loginWithEmailAllowed are off; review m4): -UserName is a plain
    name that is published nowhere (not an e-mail address, so a stranger cannot guess it and lock it out), and -Email is the address the
    realm's user profile requires (an attribute only, never a sign-in name).

    No demo identity can become an admin this way (review I1). The demo users live in the other realm, and the script still refuses,
    before changing anything, a user
      - with an e-mail address in a demo domain (*.test: every user of the demo realm file and of the demo tenants), or a service account,
      - with one of the demo realm file's fixed IDs (00000000-0000-4000-8000-...),
      - whose -Email already belongs to a different user (no e-mail fallback: the e-mail never selects a user).
    tests/Test-AddArgocdAdmin.ps1 proves each refusal against the live Keycloak.
    An existing user keeps its password unless -ResetPassword. Nothing in Git lists the user, so the keycloak-config Job leaves it alone.
    Remove the role again with -Remove (the user stays; delete it in Keycloak if wanted).
.EXAMPLE
    ./bootstrap/add-argocd-admin.ps1 -UserName <a private name> -Email <your address> -FirstName Dale -LastName Abels   # asks for the password twice
#>
[CmdletBinding()]
param(
    # The sign-in name: 3-41 characters, lower-case letters, digits, '.', '_', '-'; no '@' (realm ops signs in by user name only).
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,40}$')] [string] $UserName,
    # The user's e-mail address (the realm's user profile requires one; not a sign-in name). Needed when the user is new.
    [ValidatePattern('^$|^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,63}$')] [string] $Email = '',
    # The realm's user profile requires both names; without them Keycloak asks for them at the first sign-in.
    [ValidatePattern('^[^\r\n]{0,64}$')] [string] $FirstName = '',
    [ValidatePattern('^[^\r\n]{0,64}$')] [string] $LastName = '',
    # The folder under envs/: 'hosted' is the VM, anything else the local k3d cluster.
    [string] $Environment = 'hosted',
    # Set a new password for an existing user.
    [switch] $ResetPassword,
    # For tests and scripts only; normally the script asks.
    [securestring] $Password,
    # Take the user out of argocd-admins instead.
    [switch] $Remove
)

$Email = $Email.ToLowerInvariant()

. (Join-Path $PSScriptRoot 'common.ps1')
Select-ProcureCluster $Environment
Assert-ClusterReachable

function Read-NewPassword {
    if ($Password) { return [Net.NetworkCredential]::new('', $Password).Password }
    $first = Read-Host -AsSecureString "Password for $UserName"
    $second = Read-Host -AsSecureString 'Again'
    $a = [Net.NetworkCredential]::new('', $first).Password
    if ($a -ne [Net.NetworkCredential]::new('', $second).Password) { throw 'The two passwords differ.' }
    if ($a.Length -lt 12) { throw 'Use at least 12 characters (this user gets Argo CD admin rights).' }
    $a
}

# bash in the Keycloak pod. Arguments: action (check | add | remove), user name, first name, last name, e-mail. For add, the first stdin
# line is the password credential as one line of JSON (empty: keep the password). `check` and `add` run the same guard (refuse.. exit 6).
$script = @'
set -eu
export HOME=/tmp
cfg=$(mktemp /tmp/kcadm-XXXXXX.config)
trap 'rm -f "$cfg"' EXIT
K="/opt/keycloak/bin/kcadm.sh"
IFS= read -r CRED || true
CRED=${CRED%$'\r'}   # PowerShell ends the piped line with CRLF
KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $K config credentials --config "$cfg" --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" </dev/null >/dev/null 2>&1 || { echo "admin sign-in to Keycloak (master realm) failed"; exit 2; }
kc() { $K "$@" --config "$cfg" -r ops; }
ACTION=$1; NAME=$2; EMAIL=${5:-}
GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
[ -n "$GID" ] || { echo "group argocd-admins not found in realm ops (ops-realm.json not applied yet?)"; exit 3; }
# Exact lookups by user name and by e-mail: the e-mail may belong to no user or to this one only.
BYNAME=$(kc get users -q exact=true -q username="$NAME" --fields id --format csv --noquotes)
BYMAIL=""
[ -z "$EMAIL" ] || BYMAIL=$(kc get users -q exact=true -q email="$EMAIL" --fields id --format csv --noquotes)
UIDV=$BYNAME

if [ "$ACTION" = remove ]; then
  [ -n "$UIDV" ] || { echo "user $NAME not found"; exit 4; }
  kc delete "users/$UIDV/groups/$GID"
  echo "removed $NAME from argocd-admins"
else
  reasons=""
  refuse() { reasons="$reasons
  - $1"; }
  case "$EMAIL" in *.test) refuse "demo domain: $EMAIL is a *.test address (demo and tenant users)";; esac
  case "$NAME" in service-account-*) refuse "service account: $NAME";; esac
  if [ -n "$BYMAIL" ] && [ "$BYMAIL" != "$BYNAME" ]; then
    refuse "identifier mismatch: e-mail $EMAIL belongs to a different user (no e-mail fallback)"
  fi
  if [ -n "$UIDV" ]; then
    USERCSV=$(kc get "users/$UIDV" --fields username,email --format csv --noquotes)
    case "$USERCSV" in *.test|*.test,*) refuse "demo domain: the user's address is a *.test address";; esac
    case "$UIDV" in 00000000-0000-4000-8000-*) refuse "realm-file ID: $UIDV is a fixed ID of the realm file's demo users";; esac
  fi
  if [ -n "$reasons" ]; then
    echo "REFUSED: $NAME is not made an Argo CD admin. Reasons:$reasons"
    echo "Nothing changed."
    exit 6
  fi
  if [ "$ACTION" = check ]; then
    if [ -n "$UIDV" ]; then echo "EXISTS"; else echo "NEW"; fi
    exit 0
  fi
  if [ -z "$UIDV" ]; then
    [ -n "$CRED" ] || { echo "no password given for the new user"; exit 5; }
    [ -n "$EMAIL" ] || { echo "a new user needs -Email (the realm's user profile requires an e-mail address)"; exit 5; }
    UIDV=$(kc create users -s username="$NAME" -s email="$EMAIL" -s "firstName=$3" -s "lastName=$4" -s enabled=true -s emailVerified=true -i)
    echo "created user $NAME"
  else
    echo "user $NAME exists"
  fi
  if [ -n "$CRED" ]; then
    # The credential JSON on kcadm's stdin, not on its command line (/proc/*/cmdline).
    printf '%s' "$CRED" | kc update "users/$UIDV/reset-password" -f -
    echo "password set"
  fi
  # An authenticator app is required (ruling R6c): without an OTP credential yet, the next sign-in asks to set one up first.
  if kc get "users/$UIDV/credentials" --fields type --format csv --noquotes | grep -qx otp; then
    echo "authenticator app already set up"
  else
    # Appended to the user's pending required actions (review m5), not replacing them.
    CURRENT=$(kc get "users/$UIDV" --fields requiredActions --format csv --noquotes | tr -d '[]" ' | tr ',' '\n' | grep -v '^$' | grep -vx CONFIGURE_TOTP || true)
    LIST=$( { echo CONFIGURE_TOTP; printf '%s\n' "$CURRENT"; } | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
    kc update "users/$UIDV" -s "requiredActions=[$LIST]"
    echo "the first sign-in asks to set up an authenticator app (Configure OTP)"
  fi
  kc update "users/$UIDV/groups/$GID" -s realm=ops -s userId="$UIDV" -s groupId="$GID" -n
  echo "$NAME is in argocd-admins"
fi
echo "members of argocd-admins:"
kc get "groups/$GID/members" --fields username --format csv --noquotes
'@ -replace "`r", ''

function Invoke-KeycloakScript([string] $action, [string] $stdinLine = '') {
    $out = $stdinLine | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $script _ $action $UserName $FirstName $LastName $Email 2>&1
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Logging into' })
    if ($code -eq 6) { throw ($lines -join [Environment]::NewLine) }
    if ($code -ne 0) { $lines | Write-Host; throw "kcadm in the Keycloak pod failed ($code)." }
    $lines
}

$credential = ''
if (-not $Remove) {
    # The guard runs before any password is asked for; `add` runs it again right before the change.
    $state = (Invoke-KeycloakScript check | Select-Object -Last 1).Trim()
    if ($state -eq 'NEW' -or $ResetPassword) {
        $credential = @{ type = 'password'; value = (Read-NewPassword); temporary = $false } | ConvertTo-Json -Compress
    }
}

try {
    $out = Invoke-KeycloakScript $(if ($Remove) { 'remove' } else { 'add' }) $credential
} finally {
    $credential = $null
}
$out | Write-Host
if (-not $Remove) {
    $where = if ($Environment -eq 'hosted') { 'bootstrap/hosted/open-argocd.ps1, then "Log in via Keycloak"' } else { 'https://argocd.procure.localtest.me, "Log in via Keycloak"' }
    Write-Host "Done. Sign in to Argo CD: $where (realm ops: password, then the authenticator app's code; the first time it asks you to scan a QR code)."
}
