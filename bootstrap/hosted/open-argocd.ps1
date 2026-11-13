#Requires -Version 7.4
<#
.SYNOPSIS
    Opens Argo CD of the hosted VM on Dale's PC: by default its public address https://argocd.daleabels.com in the browser; with -Tunnel
    the SSH tunnel, kubectl port-forward to 127.0.0.1:8080 and the browser. -Close stops the port-forward and the tunnel.
.DESCRIPTION
    Default (plan 08c Task 1): opens https://<argocd host> (bootstrap/common.ps1 $HostedDomain) in the default browser and says how to sign
    in. The host sits behind a Keycloak gate: realm ops (password and the authenticator app's code), group argocd-admins only; Argo CD's
    own "Log in via Keycloak" then needs no second sign-in. The username/password login (admin) is refused there (403): use -Tunnel.
    -Tunnel (the path before plan 08c; break-glass when Keycloak or the public host is down, and the admin login):
      1. opens the SSH tunnel to the Kubernetes API (open-tunnel.ps1; an open tunnel is reused as it is),
      2. starts `kubectl port-forward svc/argocd-server 8080:80` on the loopback address only, as a hidden background process (PID in
         argocd-port-forward.pid next to the hosted kubeconfig), and waits until Argo CD answers,
      3. opens http://127.0.0.1:8080 in the default browser (-NoBrowser: not),
      4. says how to sign in, naming where the passwords are kept, never a value.
    Sign in with "Log in via Keycloak" (members of the Keycloak group argocd-admins get the admin role; Argo CD's additionalUrls and the
    Keycloak client's redirect URIs include http://127.0.0.1:8080, envs/hosted/argocd.yaml), or as admin (break-glass, when Keycloak is down).
    The port-forward ends when -Close runs, the tunnel drops or the PC restarts; run the script again.
    -Close stops the port-forward and the tunnel, but only a tunnel this script opened (a tunnel that was already open, e.g. for another
    script, is left as it is). Ownership is decided by the tunnel's ssh process, not by whether the API answers (review 12c M3): the
    marker file holds the PID of the ssh process this script started, and -Close closes the tunnel only while that same process still
    runs and no other program has a connection open through it (it says which tunnel it closes, or why it leaves it open).
#>
[CmdletBinding()]
param(
    # Stop the port-forward (and the tunnel, if this script opened it).
    [switch] $Close,
    # The SSH tunnel and a port-forward instead of the public address (break-glass, the admin login).
    [switch] $Tunnel,
    # Do not open the browser.
    [switch] $NoBrowser,
    # The local port (Argo CD's url and the Keycloak redirect URIs name 8080; another port works for the admin and API logins only).
    [int] $Port = 8080
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$pidFile = Join-Path $HostedDir 'argocd-port-forward.pid'
# Holds the PID of the tunnel's ssh process when this script opened the tunnel, so -Close closes only that one.
$tunnelMarker = Join-Path $HostedDir 'argocd-opened-tunnel'
$url = "http://127.0.0.1:$Port"

function Get-PortForwardProcess {
    # The kubectl port-forward of this script. A PID from the file counts only when it is still a kubectl port-forward of argocd-server
    # (review 12c N2: Windows reuses PIDs, and stopping some other kubectl would be wrong).
    if (-not (Test-Path $pidFile)) { return $null }
    $text = (Get-Content -Raw $pidFile).Trim()
    if ($text -notmatch '^\d+$') { return $null }
    $process = Get-Process -Id ([int] $text) -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -ne 'kubectl') { return $null }
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ("$commandLine" -match 'port-forward' -and "$commandLine" -match 'svc/argocd-server') { return $process }
    $null
}

function Get-TunnelUsers {
    # Other programs with a connection open through the tunnel's local port (kubectl port-forwards, watches): their PIDs.
    @(Get-NetTCPConnection -RemoteAddress 127.0.0.1 -RemotePort $HostedTunnelPort -State Established -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -ne $PID })
}

function Test-ArgoCdAnswers {
    try { (Invoke-WebRequest -Uri "$url/healthz" -TimeoutSec 3 -SkipHttpErrorCheck).StatusCode -eq 200 } catch { $false }
}

if ($Close) {
    $process = Get-PortForwardProcess
    if ($process) { Stop-Process -Id $process.Id; Write-Host "Port-forward closed (kubectl PID $($process.Id))." }
    else { Write-Host 'No port-forward of this script is running.' }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    $markedPid = if (Test-Path $tunnelMarker) { (Get-Content -Raw $tunnelMarker).Trim() } else { '' }
    Remove-Item $tunnelMarker -ErrorAction SilentlyContinue
    $sshTunnel = Get-HostedTunnelProcess   # not $tunnel: variables ignore case, and -Tunnel is a [switch]
    if (-not $markedPid) {
        Write-Host 'The SSH tunnel was not opened by this script: left open.'
    } elseif (-not $sshTunnel -or "$($sshTunnel.Id)" -ne $markedPid) {
        # The tunnel this script opened is gone; a tunnel running now was started by another script (or replaced): not ours to close.
        Write-Host "The SSH tunnel this script opened (ssh PID $markedPid) is no longer running$(if ($sshTunnel) { "; the open tunnel (ssh PID $($sshTunnel.Id)) belongs to another script and stays open" })."
    } else {
        Start-Sleep -Milliseconds 500   # the stopped port-forward's connection closes
        $users = @(Get-TunnelUsers)
        if ($users.Count -gt 0) {
            Write-Host "The SSH tunnel this script opened (ssh PID $markedPid) is in use by other programs (PID $($users -join ', ')): left open. Close it later with bootstrap/hosted/open-tunnel.ps1 -Close."
        } else {
            Write-Host "Closing the SSH tunnel this script opened (ssh PID $markedPid; no other program uses it)."
            & (Join-Path $PSScriptRoot 'open-tunnel.ps1') -Close
        }
    }
    return
}

if (-not $Tunnel) {
    # The public address behind the Keycloak gate (plan 08c Task 1); nothing to start on this PC.
    $publicUrl = "https://argocd.$HostedDomain"
    if (-not $NoBrowser) { Start-Process $publicUrl }
    Write-Host "Argo CD: $publicUrl"
    Write-Host '  Sign in:      your own Keycloak user of realm ops (password, then the authenticator app''s code; group argocd-admins only),'
    Write-Host '                then "Log in via Keycloak" on Argo CD''s page (no second sign-in). docs/hosting.md in procure-ai.'
    Write-Host '  Break-glass:  the admin login is refused on the public address: bootstrap/hosted/open-argocd.ps1 -Tunnel.'
    Write-Host '  Claude:       API token in user env var ARGOCD_AUTH_TOKEN_HOSTED, through the tunnel (-Tunnel) or kubectl.'
    return
}

# 1. The tunnel.
# Not Select-ProcureCluster: it opens a missing tunnel itself, and this script must know whether it did (-Close closes only its own).
# Ownership by the tunnel's ssh process (review 12c M3): a running tunnel of another script is reused and never marked as ours, even when
# the API does not answer at this moment (open-tunnel.ps1 then replaces it, and it still is not ours).
$script:KubectlArgs = @('--kubeconfig', $HostedKubeconfig, '--context', $HostedKubeContext)
$script:KubeContext = $HostedKubeContext
$tunnelWasOpen = [bool] (Get-HostedTunnelProcess)
if (-not $tunnelWasOpen -or -not (Test-ClusterReachable)) {
    & (Join-Path $PSScriptRoot 'open-tunnel.ps1') | Out-Host
}
if (-not $tunnelWasOpen) {
    $opened = Get-HostedTunnelProcess
    if ($opened) { Set-Content -Path $tunnelMarker -Value $opened.Id -NoNewline }
} elseif (Test-Path $tunnelMarker) {
    # A marker from an earlier run whose tunnel is still the one running stays; one naming another process is stale.
    if ((Get-Content -Raw $tunnelMarker).Trim() -ne "$((Get-HostedTunnelProcess).Id)") { Remove-Item $tunnelMarker -ErrorAction SilentlyContinue }
}
Assert-ClusterReachable

# 2. The port-forward (loopback only).
if ((Get-PortForwardProcess) -and (Test-ArgoCdAnswers)) {
    Write-Host "Port-forward already running: $url."
} else {
    $old = Get-PortForwardProcess
    if ($old) { Stop-Process -Id $old.Id -ErrorAction SilentlyContinue }
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listener) { throw "Port $Port is in use by another process (PID $(@($listener)[0].OwningProcess)). Free it or pass -Port." }
    $forwardArgs = @($KubectlArgs) + @('-n', 'argocd', 'port-forward', '--address', '127.0.0.1', 'svc/argocd-server', "$($Port):80")
    $quoted = $forwardArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $process = Start-Process -FilePath (Get-Command kubectl).Source -ArgumentList $quoted -WindowStyle Hidden -PassThru
    Set-Content -Path $pidFile -Value $process.Id -NoNewline
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-ArgoCdAnswers)) {
        if ($process.HasExited) { Remove-Item $pidFile -ErrorAction SilentlyContinue; throw "kubectl port-forward exited with $($process.ExitCode) (is argocd-server running? kubectl -n argocd get pods)." }
        if ((Get-Date) -gt $deadline) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue; Remove-Item $pidFile -ErrorAction SilentlyContinue; throw 'Argo CD did not answer within 30 s.' }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Port-forward open: $url -> argocd/argocd-server (kubectl PID $($process.Id))."
}

# 3. The browser.
if (-not $NoBrowser) { Start-Process $url }

# 4. How to sign in (names only, never a value).
Write-Host ''
Write-Host "Argo CD: $url"
Write-Host '  Sign in:      "Log in via Keycloak" with your own Keycloak user (group argocd-admins; docs/hosting.md in procure-ai).'
Write-Host '  Break-glass:  user admin, password in DEMO PASSWORDS.txt, "=== Argo CD ===", "Hosted admin (break-glass) password"'
Write-Host '                (also Secret argocd/argocd-initial-admin-secret on the VM).'
Write-Host '  Claude:       API token in user env var ARGOCD_AUTH_TOKEN_HOSTED (DEMO PASSWORDS.txt, same section).'
Write-Host "Close with: bootstrap/hosted/open-argocd.ps1 -Close$(if (Test-Path $tunnelMarker) { ' (also closes the tunnel this script opened, unless another program uses it)' } else { ' (the tunnel was already open and stays open)' })"
