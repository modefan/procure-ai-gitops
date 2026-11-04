#Requires -Version 7.4
<#
.SYNOPSIS
    Creates (or starts) the local k3d cluster `procure`: 1 server, 0 agents, 10 GB and 8 CPUs, kubelet memory reservations and eviction,
    ports 80/443 on the PC, CoreDNS rewrite, namespaces.
.DESCRIPTION
    Safe to run again: an existing cluster is started if stopped, its CPU cap is set again (docker update, a no-op when unchanged), and the
    CoreDNS rewrite and namespaces are re-applied. The kubelet reservations are k3s arguments, fixed when the cluster is created: an older
    cluster without them is reported, and remove-cluster.ps1 + this script recreate it (local data only).
    Before creating or starting, ports 80 and 443 on the PC must be free (k3d's load balancer binds them).
    Never run the cluster and an Aspire AppHost at the same time (CLAUDE.md "My PC is shared"); stop it with `k3d cluster stop procure`.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-DockerRunning

function Assert-PortsFree {
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 80, 443 })
    if ($busy) {
        $owners = $busy | ForEach-Object {
            $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            "port $($_.LocalPort) is used by $($process.ProcessName) (PID $($_.OwningProcess))"
        } | Sort-Object -Unique
        throw "Ports 80 and 443 must be free for the cluster's load balancer: $($owners -join '; '). Stop that program (IIS, another cluster, a dev server) and run this script again."
    }
}

$cluster = Get-K3dCluster
if (-not $cluster) {
    Assert-PortsFree
    Write-Host "Creating k3d cluster '$ClusterName' ($K3sImage, 1 server, $NodeMemory, $NodeCpus CPUs)..."
    & k3d cluster create $ClusterName `
        --image $K3sImage `
        --servers 1 --agents 0 `
        --servers-memory $NodeMemory `
        --k3s-arg "--kubelet-arg=kube-reserved=memory=$KubeReservedMemory@server:0" `
        --k3s-arg "--kubelet-arg=system-reserved=memory=$SystemReservedMemory@server:0" `
        --k3s-arg "--kubelet-arg=eviction-hard=memory.available<$EvictionHardMemory@server:0" `
        -p '80:80@loadbalancer' -p '443:443@loadbalancer' `
        --kubeconfig-update-default --kubeconfig-switch-context=false `
        --wait --timeout 300s
    if ($LASTEXITCODE -ne 0) { throw "k3d cluster create $ClusterName failed." }
} elseif ($cluster.serversRunning -lt $cluster.serversCount) {
    Assert-PortsFree
    Write-Host "Starting k3d cluster '$ClusterName'..."
    & k3d cluster start $ClusterName --wait --timeout 300s
    if ($LASTEXITCODE -ne 0) { throw "k3d cluster start $ClusterName failed." }
} else {
    Write-Host "k3d cluster '$ClusterName' is already running."
}

# The CPU cap (k3d has no flag for it): docker's limit on the server container, set on every run (no-op when unchanged; it survives
# stop/start).
$out = & docker update --cpus $NodeCpus "k3d-$ClusterName-server-0" 2>&1
if ($LASTEXITCODE -ne 0) { throw "docker update --cpus $NodeCpus k3d-$ClusterName-server-0 failed: $out" }

Assert-ClusterReachable

$budget = Get-NodeBudget
if ($budget.Cpus -ne $NodeCpus) { throw "The node has $($budget.Cpus) CPUs, expected $NodeCpus." }
$keptBack = $budget.MemoryCapacity - $budget.MemoryAllocatable
if ($keptBack -lt (Get-ExpectedKeptBack)) {
    throw "The kubelet keeps back $([math]::Round($keptBack / 1MB)) MiB, expected $([math]::Round((Get-ExpectedKeptBack) / 1MB)) MiB (kube-reserved, system-reserved, eviction-hard): this cluster was created without them. Recreate it: remove-cluster.ps1, then this script, new-local-ca.ps1 and new-secrets.ps1."
}
Write-Host "Node budget: $($budget.Cpus) CPUs, memory $([math]::Round($budget.MemoryCapacity / 1GB, 2)) GiB, allocatable $([math]::Round($budget.MemoryAllocatable / 1GB, 2)) GiB."

# CoreDNS rewrite: auth.procure.localtest.me -> Traefik, so pods reach Keycloak by the issuer's URL (plan 07 ruling 8).
$corednsData = { & kubectl --context $KubeContext -n kube-system get configmap coredns-custom -o jsonpath='{.data}' 2>$null }
$before = & $corednsData
Write-Host (Invoke-ServerSideApply -Path (Join-Path $PSScriptRoot 'coredns-custom.yaml') -Description 'ConfigMap kube-system/coredns-custom')
$removed = Remove-LastAppliedAnnotation -Kind ConfigMap -Name coredns-custom -Namespace kube-system
if ($removed) { Write-Host $removed }
if ($before -ne (& $corednsData)) {
    # CoreDNS mounts coredns-custom as an optional volume and reloads it within a minute; a restart makes it immediate.
    Invoke-Kubectl -n kube-system rollout restart deployment/coredns | Out-Null
    Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=180s | Out-Null
    Write-Host 'coredns restarted'
}

foreach ($namespace in $Namespaces) { Write-Host (Invoke-Apply (New-NamespaceObject $namespace)) }

# Traefik (k3s's bundled ingress) installs from a HelmChart a little after the API is up; new-local-ca.ps1 needs its TLSStore CRD.
Write-Host 'Waiting for Traefik...'
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    & kubectl --context $KubeContext get crd tlsstores.traefik.io -o name 2>&1 | Out-Null
    $crd = $LASTEXITCODE -eq 0
    & kubectl --context $KubeContext -n kube-system get deployment traefik -o name 2>&1 | Out-Null
    if ($crd -and $LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw 'Traefik did not appear within 5 minutes (kubectl -n kube-system get helmchart,pods).' }
    Start-Sleep -Seconds 5
}
Invoke-Kubectl -n kube-system rollout status deployment/traefik --timeout=300s | Out-Null
# The scripts pass --context; k3d adds the context to the kubeconfig but does not make it the current one.
Write-Host "Cluster '$ClusterName' is ready (context $KubeContext). Next: new-local-ca.ps1, new-secrets.ps1."
