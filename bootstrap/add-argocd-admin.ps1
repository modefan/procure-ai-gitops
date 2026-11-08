#Requires -Version 7.4
<#
.SYNOPSIS
    Gives a person's own Keycloak user Argo CD's admin role: creates the user in realm procure when it does not exist (password asked for
    here, never shown or stored), and puts it in the group argocd-admins (plan 08 Task 12c).
.DESCRIPTION
    For Dale's own user (CLAUDE.md "Hosting plan": he picks the user name and password himself; Claude does not create it). Keycloak's
    admin console is not reachable on the hosted VM (the public host serves /realms/procure/ only, and the console always sends the browser
    to that public host), so this script uses Keycloak's own admin CLI (kcadm.sh) inside the Keycloak pod, through the SSH tunnel:
      - signs in to the master realm as the bootstrap admin from the pod's own environment (KC_CLI_PASSWORD, so no admin password leaves
        the cluster or appears on a command line),
      - creates the user (enabled, e-mail verified, in no organization, so it is not a tenant user of the demo) and sets its password,
        which goes to the pod on kubectl's stdin and to Keycloak on kcadm's stdin (never on a command line),
      - adds it to argocd-admins and prints the group's members (names only).
    The realm uses the e-mail address as the user name (registrationEmailAsUsername), so -UserName is that address (-Email, if given, must
    be the same address).

    Demo users can never become admins this way (review I1): argocd-admins is all that separates the public demo accounts from Argo CD's
    role:admin once someone has the tunnel. The script refuses, before changing anything, a user
      - with an address in a demo domain (*.test: every user of the realm file and of the demo tenants), or a service account,
      - with one of the realm file's fixed IDs (00000000-0000-4000-8000-...),
      - who is a member of any organization (every demo and tenant user is; your own user is created in none),
      - found only through a different identifier (-UserName and -Email naming different addresses, or a user whose user name is not
        the address given: the old e-mail fallback could promote tom@acme.test for a typo).
    tests/Test-AddArgocdAdmin.ps1 proves each refusal against the live Keycloak.
    An existing user keeps its password unless -ResetPassword. Nothing in Git lists the user, so the keycloak-config Job leaves it alone.
    Remove the role again with -Remove (the user stays; delete it in Keycloak if wanted).
.EXAMPLE
    ./bootstrap/add-argocd-admin.ps1 -UserName dale@example.com -FirstName Dale -LastName Abels   # asks for the password twice
#>
[CmdletBinding()]
param(
    # The user's e-mail address, which is its user name in this realm.
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,63}$')] [string] $UserName,
    # Optional; must be the same address as -UserName.
    [string] $Email = '',
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

if ($Email -and $Email -ne $UserName) {
    throw "-UserName and -Email differ ('$UserName' vs '$Email'). The realm uses the e-mail address as the user name: give one address (-UserName). Nothing changed."
}
$UserName = $UserName.ToLowerInvariant()

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

# bash in the Keycloak pod. Arguments: action (check | add | remove), user name (= e-mail), first name, last name. For add, the first stdin
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
kc() { $K "$@" --config "$cfg" -r procure; }
ACTION=$1; NAME=$2
GID=$(kc get groups -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
[ -n "$GID" ] || { echo "group argocd-admins not found in realm procure (realm file not applied yet?)"; exit 3; }
# Exact lookups by user name and by e-mail: both must find the same user (or none).
BYNAME=$(kc get users -q exact=true -q username="$NAME" --fields id --format csv --noquotes)
BYMAIL=$(kc get users -q exact=true -q email="$NAME" --fields id --format csv --noquotes)
UIDV=$BYNAME

if [ "$ACTION" = remove ]; then
  [ -n "$UIDV" ] || { echo "user $NAME not found"; exit 4; }
  kc delete "users/$UIDV/groups/$GID"
  echo "removed $NAME from argocd-admins"
else
  reasons=""
  refuse() { reasons="$reasons
  - $1"; }
  case "$NAME" in *.test) refuse "demo domain: $NAME is a *.test address (demo and tenant users)";; esac
  case "$NAME" in service-account-*) refuse "service account: $NAME";; esac
  if [ -n "$BYMAIL" ] && [ "$BYMAIL" != "$BYNAME" ]; then
    refuse "identifier mismatch: the user with e-mail $NAME has a different user name (no e-mail fallback)"
  fi
  if [ -n "$UIDV" ]; then
    USERCSV=$(kc get "users/$UIDV" --fields username,email --format csv --noquotes)
    case "$USERCSV" in *.test|*.test,*) refuse "demo domain: the user's address is a *.test address";; esac
    case "$UIDV" in 00000000-0000-4000-8000-*) refuse "realm-file ID: $UIDV is a fixed ID of the realm file's demo users";; esac
    # Fails closed (re-review R1): a failed lookup stops the script; anything but an empty list refuses.
    ORGS=$(kc get "organizations/members/$UIDV/organizations" --fields alias) || { echo "organization lookup for $NAME failed: refusing, because it cannot be shown that the user is in no organization. Nothing changed."; exit 7; }
    if [ "$(printf '%s' "$ORGS" | tr -d ' \t\r\n')" != "[]" ]; then
      refuse "organization member: the user belongs to an organization (a demo or tenant user)"
    fi
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
    UIDV=$(kc create users -s username="$NAME" -s email="$NAME" -s "firstName=$3" -s "lastName=$4" -s enabled=true -s emailVerified=true -i)
    echo "created user $NAME"
  else
    echo "user $NAME exists"
  fi
  if [ -n "$CRED" ]; then
    # The credential JSON on kcadm's stdin, not on its command line (/proc/*/cmdline).
    printf '%s' "$CRED" | kc update "users/$UIDV/reset-password" -f -
    echo "password set"
  fi
  kc update "users/$UIDV/groups/$GID" -s realm=procure -s userId="$UIDV" -s groupId="$GID" -n
  echo "$NAME is in argocd-admins"
fi
echo "members of argocd-admins:"
kc get "groups/$GID/members" --fields username --format csv --noquotes
'@ -replace "`r", ''

function Invoke-KeycloakScript([string] $action, [string] $stdinLine = '') {
    $out = $stdinLine | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $script _ $action $UserName $FirstName $LastName 2>&1
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
    Write-Host "Done. Sign in to Argo CD: $where."
}
