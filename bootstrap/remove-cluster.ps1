#Requires -Version 7.4
<#
.SYNOPSIS
    Deletes the local k3d cluster `procure` with all its data (every PVC: databases, Debezium offsets).
.DESCRIPTION
    Asks for confirmation unless -Confirm:$false is given. The local CA in %USERPROFILE%\.procure-ai\local-ca\ and the AppHost user
    secrets are kept, so new-cluster.ps1 + new-local-ca.ps1 + new-secrets.ps1 rebuild the same trust and credentials.
    To pause the cluster and keep its data, use `k3d cluster stop procure` instead.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-DockerRunning

$cluster = & k3d cluster list -o json | ConvertFrom-Json | Where-Object name -eq $ClusterName
if (-not $cluster) { Write-Host "No k3d cluster '$ClusterName'."; return }
if ($PSCmdlet.ShouldProcess("k3d cluster '$ClusterName' and all its volumes", 'Delete')) {
    & k3d cluster delete $ClusterName
    if ($LASTEXITCODE -ne 0) { throw "k3d cluster delete $ClusterName failed." }
    Write-Host "Cluster '$ClusterName' deleted. The local CA ($LocalCaDir) is kept."
}
