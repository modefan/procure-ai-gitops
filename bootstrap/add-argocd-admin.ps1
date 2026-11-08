#Requires -Version 7.4
<#
.SYNOPSIS
    Gives a person's own Keycloak user Argo CD's admin role: creates the user in realm procure when it does not exist (password asked for
    here, never shown or stored), and puts it in the group argocd-admins (plan 08 Task 12c).
.DESCRIPTION
    For Dale's own user (CLAUDE.md "Hosting plan": he picks the user name and password himself; Claude does not create it). Keycloak's
    admin console is not reachable on the hosted VM (the public host serves /realms/procure/ only, and the console always sends the browser
    to that public host), so this script uses Keycloak's own admin CLI (kcadm.sh) inside the Keycloak pod, through the SSH tunnel:
      - signs in to the master realm as the bootstrap admin from the pod's own environment (no admin password leaves the cluster),
      - creates the user (enabled, e-mail verified, in no organization, so it is not a tenant user of the demo) and sets its password,
        which goes to the pod on kubectl's stdin (not on a command line),
      - adds it to argocd-admins and prints the group's members (names only).
    The realm uses the e-mail as the user name when one is given (registrationEmailAsUsername), so later runs find the user by -UserName
    or -Email. An existing user keeps its password unless -ResetPassword. Nothing in Git lists the user, so the keycloak-config Job leaves it alone.
    Remove the role again with -Remove (the user stays; delete it in Keycloak if wanted).
.EXAMPLE
    ./bootstrap/add-argocd-admin.ps1 -UserName dale -Email dale@example.com -FirstName Dale -LastName Abels   # asks for the password twice
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._@+-]{2,64}$')] [string] $UserName,
    [ValidatePattern('^$|^[^@\s]+@[^@\s]+\.[^@\s]+$')] [string] $Email = '',
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

# bash in the Keycloak pod. Arguments: action, user name, e-mail, first name, last name; the new password (if any) is the first stdin line.
$script = @'
set -eu
export HOME=/tmp
cfg=$(mktemp /tmp/kcadm-XXXXXX.config)
trap 'rm -f "$cfg"' EXIT
K="/opt/keycloak/bin/kcadm.sh"
IFS= read -r NEWPW || true
NEWPW=${NEWPW%$'\r'}   # PowerShell ends the piped line with CRLF
$K config credentials --config "$cfg" --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "admin sign-in to Keycloak (master realm) failed"; exit 2; }
GID=$($K get groups --config "$cfg" -r procure -q exact=true -q search=argocd-admins --fields id,name --format csv --noquotes | while IFS=, read -r id name; do [ "$name" = argocd-admins ] && echo "$id"; done || true)
[ -n "$GID" ] || { echo "group argocd-admins not found in realm procure (realm file not applied yet?)"; exit 3; }
UIDV=$($K get users --config "$cfg" -r procure -q exact=true -q username="$2" --fields id --format csv --noquotes)
[ -n "$UIDV" ] || [ -z "$3" ] || UIDV=$($K get users --config "$cfg" -r procure -q exact=true -q email="$3" --fields id --format csv --noquotes)
if [ "$1" = remove ]; then
  [ -n "$UIDV" ] || { echo "user $2 not found"; exit 4; }
  $K delete "users/$UIDV/groups/$GID" --config "$cfg" -r procure
  echo "removed $2 from argocd-admins"
else
  if [ -z "$UIDV" ]; then
    [ -n "$NEWPW" ] || { echo "no password given for the new user"; exit 5; }
    EMAILARGS=""; [ -n "$3" ] && EMAILARGS="-s email=$3"
    UIDV=$($K create users --config "$cfg" -r procure -s username="$2" $EMAILARGS -s "firstName=$4" -s "lastName=$5" -s enabled=true -s emailVerified=true -i)
    echo "created user $2 (the realm uses the e-mail as user name when one is given)"
  else
    echo "user $2 exists"
  fi
  if [ -n "$NEWPW" ]; then
    $K set-password --config "$cfg" -r procure --userid "$UIDV" --new-password "$NEWPW"
    echo "password set"
  fi
  $K update "users/$UIDV/groups/$GID" --config "$cfg" -r procure -s realm=procure -s userId="$UIDV" -s groupId="$GID" -n
  echo "$2 is in argocd-admins"
fi
echo "members of argocd-admins:"
$K get "groups/$GID/members" --config "$cfg" -r procure --fields username --format csv --noquotes
'@

$userExists = $false
$action = if ($Remove) { 'remove' } else { 'add' }
$newPassword = ''
if (-not $Remove) {
    $found = & kubectl @KubectlArgs -n procure exec deploy/keycloak -c keycloak -- bash -c @'
export HOME=/tmp; cfg=$(mktemp /tmp/kcadm-XXXXXX.config); trap 'rm -f "$cfg"' EXIT; K=/opt/keycloak/bin/kcadm.sh
$K config credentials --config "$cfg" --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
U=$($K get users --config "$cfg" -r procure -q exact=true -q username="$1" --fields id --format csv --noquotes)
[ -n "$U" ] || [ -z "$2" ] || U=$($K get users --config "$cfg" -r procure -q exact=true -q email="$2" --fields id --format csv --noquotes)
echo "$U"
'@ _ $UserName $Email 2>&1
    if ($LASTEXITCODE -ne 0) { throw "looking up $UserName in Keycloak failed: $($found -join ' ')" }
    $userExists = -not [string]::IsNullOrWhiteSpace("$found")
    if (-not $userExists -or $ResetPassword) { $newPassword = Read-NewPassword }
}

$out = $newPassword | & kubectl @KubectlArgs -n procure exec -i deploy/keycloak -c keycloak -- bash -c $script _ $action $UserName $Email $FirstName $LastName 2>&1
$code = $LASTEXITCODE
$newPassword = $null
$out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Logging into' } | Write-Host
if ($code -ne 0) { throw "kcadm in the Keycloak pod failed ($code)." }
if (-not $Remove) {
    $where = if ($Environment -eq 'hosted') { 'bootstrap/hosted/open-argocd.ps1, then "Log in via Keycloak"' } else { 'https://argocd.procure.localtest.me, "Log in via Keycloak"' }
    Write-Host "Done. Sign in to Argo CD: $where."
}
