#Requires -Version 7.4
<#
.SYNOPSIS
    Opens (or closes) the SSH tunnel from Dale's PC to the hosted VM's Kubernetes API.
.DESCRIPTION
    The API listens only on the VM's node address (a dummy interface; infra/hosted: k3s bind-address) and Contabo's firewall lets in only 22, 80 and
    443, so kubectl and helm reach it only through this tunnel: ssh -N -L 127.0.0.1:16443:<private address>:6443 as the admin user, with
    the VM's own key and known_hosts from %USERPROFILE%\.procure-ai\hosted\. The kubeconfig there points at https://127.0.0.1:16443.
    The tunnel runs as a hidden background ssh process (PID in tunnel.pid) until -Close, a reboot of the PC or the VM, or a network
    drop (ssh exits after about 90 s without an answer; run this script again). Listens on the loopback address only.
    Safe to run again: an open tunnel that answers is left as it is.
#>
[CmdletBinding()]
param(
    # Close the tunnel this script opened (the PID in tunnel.pid).
    [switch] $Close
)

. (Join-Path $PSScriptRoot '..\common.ps1')

function Test-PortOpen([int] $port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync('127.0.0.1', $port).Wait(1000) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

if ($Close) {
    $process = Get-HostedTunnelProcess
    if ($process) {
        Stop-Process -Id $process.Id
        Write-Host "Tunnel closed (ssh PID $($process.Id))."
    } else {
        Write-Host 'No tunnel of this script is running.'
    }
    Remove-Item $HostedTunnelPidFile -ErrorAction SilentlyContinue
    return
}

$hostInfo = Get-HostedHost
$kubeArgs = @('--kubeconfig', $HostedKubeconfig, '--context', $HostedKubeContext)
if ((Get-HostedTunnelProcess) -and (Test-PortOpen $HostedTunnelPort)) {
    & kubectl @kubeArgs get --raw /readyz 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Tunnel already open: 127.0.0.1:$HostedTunnelPort -> $($hostInfo.nodeIp):6443."; return }
    # A tunnel whose far end no longer answers (VM rebooted, network dropped): replace it.
    Stop-Process -Id (Get-HostedTunnelProcess).Id -ErrorAction SilentlyContinue
}
if (Test-PortOpen $HostedTunnelPort) {
    throw "Port 127.0.0.1:$HostedTunnelPort is in use by another process (not this script's tunnel). Free it and run this script again."
}

$sshArgs = @(Get-HostedSshArgs) + @(
    '-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
    '-L', "127.0.0.1:$($HostedTunnelPort):$($hostInfo.nodeIp):6443", "$($hostInfo.user)@$($hostInfo.ipv4)")
# Quote each argument for Start-Process (paths under the profile may hold spaces).
$quoted = $sshArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$process = Start-Process -FilePath (Get-Command ssh).Source -ArgumentList $quoted -WindowStyle Hidden -PassThru
Set-Content -Path $HostedTunnelPidFile -Value $process.Id -NoNewline

$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-PortOpen $HostedTunnelPort)) {
    if ($process.HasExited) { Remove-Item $HostedTunnelPidFile -ErrorAction SilentlyContinue; throw "ssh exited with $($process.ExitCode) before the tunnel opened (is the VM up? bootstrap/hosted/Test-HostBaseline.ps1)." }
    if ((Get-Date) -gt $deadline) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue; throw 'The tunnel did not open within 30 s.' }
    Start-Sleep -Milliseconds 500
}
Write-Host "Tunnel open: 127.0.0.1:$HostedTunnelPort -> $($hostInfo.nodeIp):6443 on $($hostInfo.ipv4) (ssh PID $($process.Id); close with -Close)."
