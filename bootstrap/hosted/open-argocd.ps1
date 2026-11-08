#Requires -Version 7.4
<#
.SYNOPSIS
    Opens Argo CD of the hosted VM on Dale's PC: SSH tunnel, kubectl port-forward to 127.0.0.1:8080 and the browser. -Close stops both.
.DESCRIPTION
    Argo CD has no public address on the VM (plan 08 ruling 4). This script
      1. opens the SSH tunnel to the Kubernetes API (open-tunnel.ps1; an open tunnel is reused as it is),
      2. starts `kubectl port-forward svc/argocd-server 8080:80` on the loopback address only, as a hidden background process (PID in
         argocd-port-forward.pid next to the hosted kubeconfig), and waits until Argo CD answers,
      3. opens http://127.0.0.1:8080 in the default browser (-NoBrowser: not),
      4. says how to sign in, naming where the passwords are kept, never a value.
    Sign in with "Log in via Keycloak" (members of the Keycloak group argocd-admins get the admin role; Argo CD's url and the Keycloak
    client's redirect URIs are http://127.0.0.1:8080, envs/hosted/argocd.yaml), or as admin (break-glass, when Keycloak is down).
    The port-forward ends when -Close runs, the tunnel drops or the PC restarts; run the script again.
    -Close stops the port-forward and the tunnel, but only a tunnel this script opened (a tunnel that was already open, e.g. for another
    script, is left as it is).
#>
[CmdletBinding()]
param(
    # Stop the port-forward (and the tunnel, if this script opened it).
    [switch] $Close,
    # Do not open the browser.
    [switch] $NoBrowser,
    # The local port (Argo CD's url and the Keycloak redirect URIs name 8080; another port works for the admin and API logins only).
    [int] $Port = 8080
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$pidFile = Join-Path $HostedDir 'argocd-port-forward.pid'
# Set when this script opened the tunnel, so -Close closes only its own.
$tunnelMarker = Join-Path $HostedDir 'argocd-opened-tunnel'
$url = "http://127.0.0.1:$Port"

function Get-PortForwardProcess {
    if (-not (Test-Path $pidFile)) { return $null }
    $forwardPid = [int] (Get-Content -Raw $pidFile).Trim()
    $process = Get-Process -Id $forwardPid -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq 'kubectl') { return $process }
    $null
}

function Test-ArgoCdAnswers {
    try { (Invoke-WebRequest -Uri "$url/healthz" -TimeoutSec 3 -SkipHttpErrorCheck).StatusCode -eq 200 } catch { $false }
}

if ($Close) {
    $process = Get-PortForwardProcess
    if ($process) { Stop-Process -Id $process.Id; Write-Host "Port-forward closed (kubectl PID $($process.Id))." }
    else { Write-Host 'No port-forward of this script is running.' }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    if (Test-Path $tunnelMarker) {
        & (Join-Path $PSScriptRoot 'open-tunnel.ps1') -Close
        Remove-Item $tunnelMarker -ErrorAction SilentlyContinue
    } else {
        Write-Host 'The SSH tunnel was not opened by this script: left open.'
    }
    return
}

# 1. The tunnel.
# Not Select-ProcureCluster: it opens a missing tunnel itself, and this script must know whether it did (-Close closes only its own).
$tunnelWasOpen = $false
$script:KubectlArgs = @('--kubeconfig', $HostedKubeconfig, '--context', $HostedKubeContext)
$script:KubeContext = $HostedKubeContext
if (Test-ClusterReachable) { $tunnelWasOpen = $true }
else {
    & (Join-Path $PSScriptRoot 'open-tunnel.ps1') | Out-Host
    Set-Content -Path $tunnelMarker -Value (Get-Date -Format o) -NoNewline
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
Write-Host "Close with: bootstrap/hosted/open-argocd.ps1 -Close$(if ($tunnelWasOpen) { ' (the tunnel was already open and stays open)' })"
