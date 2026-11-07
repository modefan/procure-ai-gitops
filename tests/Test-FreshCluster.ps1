#Requires -Version 7.4
<#
.SYNOPSIS
    From a deleted cluster: the four bootstrap scripts, then Argo CD alone brings the whole system up (plan 07 Review Focus 1).
.DESCRIPTION
    DELETES the local cluster `procure` and all its data, then runs new-cluster.ps1, new-local-ca.ps1, new-secrets.ps1 and
    install-argocd.ps1, and waits (at most -TimeoutMinutes from the start of install-argocd.ps1) until
      - every Application (root, argocd, platform, procure-ai, and observability when apps.yaml enables it) is Synced and Healthy by its
        own health (not the wave gate) and its last sync Succeeded (the demo seed is procure-ai's PostSync hook, so it has run), and
      - every pod in procure, argocd and observability is Ready (Jobs' pods: Succeeded).
    Then it waits -StableSeconds more and checks that every pod is still Ready and no container restarted in that time (a pod that
    crashes on its first message, not at start, shows up here), and runs Test-Smoke.ps1.
    It fails early, with the container's last log lines, when a container crash-loops (CrashLoopBackOff for -CrashLoopMinutes or
    -MaxRestarts restarts), an image cannot be pulled for 3 minutes, a container's configuration is wrong (CreateContainerConfigError,
    e.g. a missing Secret key) for 2 minutes, a pod is evicted, or Windows has less than -MinFreeGB of free memory (the PC is shared).
    Pods may restart while dependencies come up; nothing may stay broken.
    Reports the node's peak memory (docker stats of the k3d server) and the lowest free Windows memory seen.

    The images are pulled from GHCR (ghcr.io/modefan/procure-ai-<name>:<appRevision>, envs/<env>/release.yaml) unless -LocalImages is
    given: then they must be in the local Docker engine under those names (deploy/scripts/build-images.ps1 -Tag <appRevision>
    -Registry ghcr.io/modefan, in a procure-ai checkout of that revision) and are imported into the new cluster before Argo CD starts,
    for a check before CI has published the revision. Exit code 1 on any failure.

    -Environment hosted works with -WatchOnly only (the hosted VM is never deleted by a test): it watches the hosted cluster through the
    SSH tunnel and reports the node's peak memory from `kubectl top node` instead of docker stats; the smoke checks run with
    -Environment hosted.
#>
[CmdletBinding()]
param(
    [string] $Environment = 'local',
    [switch] $LocalImages,
    # Skip the delete and bootstrap: only wait for, watch and smoke-check the running cluster (e.g. after a deploy, or to see the
    # failure checks work).
    [switch] $WatchOnly,
    [int] $TimeoutMinutes = 15,
    [int] $StableSeconds = 120,
    [int] $CrashLoopMinutes = 4,
    [int] $MaxRestarts = 8,
    [double] $MinFreeGB = 3.5
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$hosted = $Environment -eq 'hosted'
if ($hosted -and -not $WatchOnly) { throw '-Environment hosted needs -WatchOnly: a test never deletes the hosted cluster.' }
Select-ProcureCluster $Environment
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bootstrap = Join-Path $repoRoot 'bootstrap'
$watchedNamespaces = @('procure', 'argocd', 'observability')
$imageNames = @('access-api', 'approvals-api', 'assistant-api', 'audit-api', 'budgets-api', 'invoicing-api', 'notifications-api',
    'purchasing-api', 'requests-api', 'suppliers-api', 'gateway', 'simulators', 'demo-data', 'web', 'postgres', 'keycloak', 'debezium')

function Write-Step([string] $text) { Write-Host "`n== $(Get-Date -Format HH:mm:ss) $text" -ForegroundColor Cyan }
function Stop-Test([string] $message) {
    Write-Host "`nFAIL: $message" -ForegroundColor Red
    Write-Summary
    exit 1
}

$release = Get-Content -Raw (Join-Path $repoRoot "envs/$Environment/release.yaml")
if ($release -notmatch '(?m)^appRevision:\s*"?([0-9a-f]{40})"?\s*$') { throw "envs/$Environment/release.yaml has no full appRevision." }
$appRevision = $Matches[1]
# Platform images are tagged by their build context (release.yaml platformImageTags); without a tag they take appRevision.
$platformImages = @('postgres', 'keycloak', 'debezium')
$platformTags = @{}
foreach ($name in $platformImages) {
    $platformTags[$name] = if ($release -match "(?m)^\s+`"?${name}`"?:\s*`"?([0-9a-f]{40})`"?\s*$") { $Matches[1] } else { $appRevision }
}
$apps = Get-Content -Raw (Join-Path $repoRoot "envs/$Environment/apps.yaml")
$expectedApps = @('root', 'argocd', 'platform', 'procure-ai')
if ($apps -match '(?ms)^observability:\s*\n\s+(#[^\n]*\n\s+)*enabled:\s*true') { $expectedApps += 'observability' }

$script:peakNodeBytes = 0L
$script:minFreeGB = [double]::MaxValue
$script:convergedAfter = $null

function ConvertFrom-DockerSize([string] $text) {
    if ($text -match '^([\d.]+)\s*([KMGT]i?B|B)$') {
        $factor = switch ($Matches[2]) { 'B' { 1 } 'KiB' { 1KB } 'KB' { 1e3 } 'MiB' { 1MB } 'MB' { 1e6 } 'GiB' { 1GB } 'GB' { 1e9 } 'TiB' { 1TB } default { 1 } }
        return [int64]([double]$Matches[1] * $factor)
    }
    0L
}

function Measure-Memory {
    if ($hosted) {
        # The VM's node as the kubelet sees it (metrics-server), e.g. "vmi3735351  420m  5%  6123Mi  26%".
        $top = & kubectl @KubectlArgs top node --no-headers 2>$null
        if ($LASTEXITCODE -eq 0 -and "$top" -match '\s(\d+)Mi\s') {
            $bytes = [int64] $Matches[1] * 1MB
            if ($bytes -gt $script:peakNodeBytes) { $script:peakNodeBytes = $bytes }
        }
        return
    }
    $usage = & docker stats --no-stream --format '{{.MemUsage}}' "k3d-$ClusterName-server-0" 2>$null
    if ($LASTEXITCODE -eq 0 -and $usage) {
        $bytes = ConvertFrom-DockerSize (("$usage" -split '/')[0].Trim())
        if ($bytes -gt $script:peakNodeBytes) { $script:peakNodeBytes = $bytes }
    }
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($free -lt $script:minFreeGB) { $script:minFreeGB = $free }
    if ($free -lt $MinFreeGB) { Stop-Test ("Windows has only {0:N1} GB free memory (minimum {1} GB): stopping so the PC stays responsive." -f $free, $MinFreeGB) }
}

function Write-Summary {
    Write-Host ''
    if ($script:convergedAfter) { Write-Host ("Converged {0:mm\:ss} after install-argocd.ps1 started." -f $script:convergedAfter) }
    if ($script:peakNodeBytes -gt 0) {
        if ($hosted) { Write-Host ("Node memory peak (kubectl top node): {0:N2} GiB." -f ($script:peakNodeBytes / 1GB)) }
        else { Write-Host ("Node memory peak (docker stats): {0:N2} GiB of {1}." -f ($script:peakNodeBytes / 1GB), $NodeMemory) }
    }
    if ($script:minFreeGB -lt [double]::MaxValue) { Write-Host ("Windows free memory, lowest seen: {0:N1} GB." -f $script:minFreeGB) }
    if (Test-ClusterReachable) {
        $out = & kubectl @KubectlArgs -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase,REVISION:.status.sync.revisions[0]' 2>&1
        Write-Host ($out -join "`n")
        $top = & kubectl @KubectlArgs top pods -n argocd --no-headers 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "Argo CD pods (kubectl top):`n$($top -join "`n")" }
    }
}

function Get-Pods {
    $all = @()
    foreach ($ns in $watchedNamespaces) {
        $json = & kubectl @KubectlArgs -n $ns get pods -o json 2>$null
        if ($LASTEXITCODE -eq 0) { $all += @(($json | Out-String | ConvertFrom-Json).items) }
    }
    # Pods the kubelet's graceful node shutdown ended (a VM reboot, plan 08 Task 12) stay as Failed objects with this reason and message
    # until deleted; their Deployment or StatefulSet has replaced them. They are not broken pods of the running system.
    @($all | Where-Object {
            -not ($_.status.phase -eq 'Failed' -and $_.status.PSObject.Properties['reason'] -and $_.status.reason -eq 'Terminated' -and
                $_.status.PSObject.Properties['message'] -and "$($_.status.message)" -like '*imminent node shutdown*') })
}

function Get-ContainerStatuses($pod) {
    $list = @()
    if ($pod.status.PSObject.Properties['initContainerStatuses']) { $list += @($pod.status.initContainerStatuses) }
    if ($pod.status.PSObject.Properties['containerStatuses']) { $list += @($pod.status.containerStatuses) }
    $list
}

function Get-WaitingReason($container) {
    if ($container.state.PSObject.Properties['waiting'] -and $container.state.waiting.PSObject.Properties['reason']) { return $container.state.waiting.reason }
    $null
}

function Test-PodReady($pod) {
    if ($pod.status.phase -eq 'Succeeded') { return $true }
    if ($pod.status.phase -ne 'Running') { return $false }
    $ready = @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
    $ready.Count -gt 0
}

function Get-OwnerKind($pod) {
    if ($pod.metadata.PSObject.Properties['ownerReferences']) { return @($pod.metadata.ownerReferences)[0].kind }
    ''
}

function Show-ContainerLog($pod, [string] $container) {
    $ns = $pod.metadata.namespace; $name = $pod.metadata.name
    Write-Host "--- last log lines of $ns/$name ($container), previous run:" -ForegroundColor Yellow
    $log = & kubectl @KubectlArgs -n $ns logs $name -c $container --previous --tail 30 2>&1
    if ($LASTEXITCODE -ne 0) { $log = & kubectl @KubectlArgs -n $ns logs $name -c $container --tail 30 2>&1 }
    Write-Host ($log -join "`n")
}

# Since when each (pod, container, reason) has been seen in a bad state.
$badSince = @{}
function Assert-NoBrokenPods($pods) {
    $now = Get-Date
    $seen = @{}
    foreach ($pod in $pods) {
        $id = "$($pod.metadata.namespace)/$($pod.metadata.name)"
        if ($pod.status.PSObject.Properties['reason'] -and $pod.status.reason -eq 'Evicted') {
            Stop-Test "pod $id was evicted: $($pod.status.message)"
        }
        foreach ($c in Get-ContainerStatuses $pod) {
            $reason = Get-WaitingReason $c
            if (-not $reason) { continue }
            $limit = switch ($reason) {
                'CrashLoopBackOff' { [TimeSpan]::FromMinutes($CrashLoopMinutes) }
                { $_ -in 'ImagePullBackOff', 'ErrImagePull', 'InvalidImageName' } { [TimeSpan]::FromMinutes(3) }
                { $_ -in 'CreateContainerConfigError', 'CreateContainerError' } { [TimeSpan]::FromMinutes(2) }
                default { $null }
            }
            if (-not $limit) { continue }
            $key = "$id|$($c.name)|$reason"
            $seen[$key] = $true
            if (-not $badSince.ContainsKey($key)) { $badSince[$key] = $now }
            $for = $now - $badSince[$key]
            if ($reason -eq 'CrashLoopBackOff' -and $c.restartCount -ge $MaxRestarts) {
                Show-ContainerLog $pod $c.name
                Stop-Test "container $id ($($c.name)) crash-loops: $($c.restartCount) restarts"
            }
            if ($for -ge $limit) {
                $message = if ($c.state.waiting.PSObject.Properties['message']) { $c.state.waiting.message } else { '' }
                if ($reason -eq 'CrashLoopBackOff') { Show-ContainerLog $pod $c.name }
                Stop-Test ("container $id ($($c.name)) has been in {0} for {1:mm\:ss} ({2} restarts): {3}" -f $reason, $for, $c.restartCount, $message)
            }
        }
    }
    foreach ($key in @($badSince.Keys)) { if (-not $seen.ContainsKey($key)) { $badSince.Remove($key) } }
}

function Get-AppState {
    $json = & kubectl @KubectlArgs -n argocd get applications -o json 2>$null
    if ($LASTEXITCODE -ne 0) { return @{} }
    $state = @{}
    foreach ($app in ($json | Out-String | ConvertFrom-Json).items) {
        $s = $app.PSObject.Properties['status'] ? $app.status : $null
        $state[$app.metadata.name] = [pscustomobject]@{
            Sync      = if ($s -and $s.PSObject.Properties['sync']) { $s.sync.status } else { '' }
            Health    = if ($s -and $s.PSObject.Properties['health']) { $s.health.status } else { '' }
            Operation = if ($s -and $s.PSObject.Properties['operationState']) { $s.operationState.phase } else { '' }
            Message   = if ($s -and $s.PSObject.Properties['operationState'] -and $s.operationState.PSObject.Properties['message']) { $s.operationState.message } else { '' }
            Revision  = if ($s -and $s.PSObject.Properties['sync'] -and $s.sync.PSObject.Properties['revisions']) { @($s.sync.revisions)[0] } else { '' }
        }
    }
    $state
}

$suiteStart = Get-Date
$importTime = [TimeSpan]::Zero
# --- 1. From nothing --------------------------------------------------------------------------------------------------------------
if (-not $hosted) { Assert-DockerRunning }
Measure-Memory
if (-not $WatchOnly) {
Write-Step "Deleting cluster '$ClusterName' (all its data) and bootstrapping envs/$Environment at appRevision $appRevision"
& (Join-Path $bootstrap 'remove-cluster.ps1') -Confirm:$false
foreach ($script in 'new-cluster.ps1', 'new-local-ca.ps1', 'new-secrets.ps1') {
    Write-Step $script
    & (Join-Path $bootstrap $script)
    Measure-Memory
}
}

if ($LocalImages -and -not $WatchOnly) {
    Write-Step "Importing the local images ghcr.io/modefan/procure-ai-*:$appRevision"
    $images = $imageNames | ForEach-Object { "ghcr.io/modefan/procure-ai-${_}:$(if ($platformTags.ContainsKey($_)) { $platformTags[$_] } else { $appRevision })" }
    $missing = @($images | Where-Object { & docker image inspect $_ --format '{{.Id}}' 2>$null | Out-Null; $LASTEXITCODE -ne 0 })
    if ($missing) { Stop-Test "not in the local Docker engine: $($missing -join ', ') (build them in a procure-ai checkout of that revision: deploy/scripts/build-images.ps1 -Tag $appRevision -Registry ghcr.io/modefan -ContentTagPlatform)" }
    $importStart = Get-Date
    & k3d image import @images --cluster $ClusterName
    if ($LASTEXITCODE -ne 0) { Stop-Test 'k3d image import failed.' }
    $importTime = (Get-Date) - $importStart
    Measure-Memory
}

# --- 2. Argo CD takes over ---------------------------------------------------------------------------------------------------------
$start = Get-Date
if (-not $WatchOnly) {
    Write-Step 'install-argocd.ps1'
    & (Join-Path $bootstrap 'install-argocd.ps1') -Environment $Environment
}
# Review Focus 1: "from a deleted cluster ... within 15 minutes": the clock starts with the delete; the time spent importing local images
# (a stand-in for pulls from GHCR that only -LocalImages needs) is not counted. -WatchOnly: from the start of the watch.
$deadline = $suiteStart.AddMinutes($TimeoutMinutes) + $importTime

Write-Step "Waiting until every Application is Synced and Healthy and every pod Ready (until $($deadline.ToString('HH:mm:ss')))"
$lastReport = ''
while ($true) {
    Measure-Memory
    $pods = Get-Pods
    Assert-NoBrokenPods $pods
    $state = Get-AppState
    $notDone = @()
    foreach ($name in $expectedApps) {
        $a = $state[$name]
        if (-not $a) { $notDone += "$name (missing)"; continue }
        if ($a.Sync -ne 'Synced' -or $a.Health -ne 'Healthy' -or $a.Operation -ne 'Succeeded') {
            $notDone += "$name ($($a.Sync)/$($a.Health)/$($a.Operation))"
        } elseif ($name -in 'platform', 'procure-ai', 'observability' -and $a.Revision -ne $appRevision) {
            # Not yet at the release's revision (a deploy Argo CD has not picked up yet).
            $notDone += "$name (at $("$($a.Revision)".Substring(0, [Math]::Min(7, "$($a.Revision)".Length))), not $($appRevision.Substring(0, 7)))"
        }
    }
    $notReady = @($pods | Where-Object { -not (Test-PodReady $_) -and $_.status.phase -ne 'Failed' } |
        ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" })
    # A failed Job pod is fine while its Job retries; a failed pod of anything else is not.
    $failedPods = @($pods | Where-Object { $_.status.phase -eq 'Failed' -and (Get-OwnerKind $_) -ne 'Job' } |
        ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" })
    if ($failedPods) { Stop-Test "pods failed: $($failedPods -join ', ')" }
    if (-not $notDone -and -not $notReady -and $pods.Count -gt 0) { break }

    $elapsed = (Get-Date) - $start
    $report = "apps not done: $($notDone -join ', '); pods not ready: $($notReady.Count)"
    if ($report -ne $lastReport) { Write-Host ("{0:mm\:ss} {1}" -f $elapsed, $report); $lastReport = $report }
    if ((Get-Date) -gt $deadline) {
        $crashLooping = @($pods | ForEach-Object { $p = $_; Get-ContainerStatuses $p | Where-Object { (Get-WaitingReason $_) -eq 'CrashLoopBackOff' } |
            ForEach-Object { "$($p.metadata.namespace)/$($p.metadata.name) ($($_.name))" } })
        Stop-Test "not converged within $TimeoutMinutes minutes. Apps: $($notDone -join ', '). Pods not Ready: $($notReady -join ', ').$(if ($crashLooping) { " CrashLoopBackOff: $($crashLooping -join ', ')." })"
    }
    Start-Sleep -Seconds 15
}
$script:convergedAfter = (Get-Date) - $start
$convergedFromStart = (Get-Date) - $suiteStart - $importTime
Write-Host ("Converged {0:mm\:ss} after install-argocd.ps1 (or the watch) started, {1:mm\:ss} after the start of the run (image import of {2:mm\:ss} not counted)." -f $script:convergedAfter, $convergedFromStart, $importTime) -ForegroundColor Green

# --- Wave order: the apps synced this revision only after the platform's sync of it finished (the wave gate, argocd/values.yaml). ----
$json = Invoke-Kubectl -n argocd get applications platform procure-ai -o json | Out-String | ConvertFrom-Json
$byName = @{}; foreach ($a in $json.items) { $byName[$a.metadata.name] = $a }
foreach ($name in 'platform', 'procure-ai') {
    $revision = @($byName[$name].status.sync.revisions)[0]
    if ($revision -ne $appRevision) { Stop-Test "$name is synced at $revision, expected appRevision $appRevision" }
}
$platformDone = [datetimeoffset] $byName['platform'].status.operationState.finishedAt
$appsStarted = [datetimeoffset] $byName['procure-ai'].status.operationState.startedAt
if ($WatchOnly -and $appsStarted -lt [datetimeoffset] $suiteStart) {
    # Nothing synced during this watch (e.g. after a VM reboot the pods restart but no sync runs): the last operations may come from
    # different rollouts or a manual sync, so their order says nothing.
    Write-Host "Wave order: no procure-ai sync during this watch (its last started $($appsStarted.ToLocalTime().ToString('HH:mm:ss'))); not checked."
} elseif ($appsStarted -lt $platformDone) {
    Stop-Test "procure-ai's sync started at $($appsStarted.ToLocalTime().ToString('HH:mm:ss')), before the platform's sync finished at $($platformDone.ToLocalTime().ToString('HH:mm:ss'))"
} else {
    Write-Host "Wave order ok: platform's sync finished $($platformDone.ToLocalTime().ToString('HH:mm:ss')), procure-ai's started $($appsStarted.ToLocalTime().ToString('HH:mm:ss')) (both at $($appRevision.Substring(0, 7)))."
}

# --- 3. Stable: nothing restarts or drops out of Ready -------------------------------------------------------------------------------
function Get-RestartCounts($pods) {
    $counts = @{}
    foreach ($pod in $pods) {
        foreach ($c in Get-ContainerStatuses $pod) { $counts["$($pod.metadata.namespace)/$($pod.metadata.name)|$($c.name)"] = $c.restartCount }
    }
    $counts
}
$restartsBefore = Get-RestartCounts $pods
Write-Step "Watching $StableSeconds s for restarts"
$stableUntil = (Get-Date).AddSeconds($StableSeconds)
while ((Get-Date) -lt $stableUntil) { Start-Sleep -Seconds 15; Measure-Memory; Assert-NoBrokenPods (Get-Pods) }
$pods = Get-Pods
$restartsAfter = Get-RestartCounts $pods
$restarted = @($restartsAfter.Keys | Where-Object { $restartsBefore.ContainsKey($_) -and $restartsAfter[$_] -gt $restartsBefore[$_] })
if ($restarted) {
    $pods | ForEach-Object { $p = $_; Get-ContainerStatuses $p | Where-Object { $restarted -contains "$($p.metadata.namespace)/$($p.metadata.name)|$($_.name)" } |
        ForEach-Object { Show-ContainerLog $p $_.name } }
    Stop-Test "containers restarted after convergence: $($restarted -join ', ')"
}
$notReady = @($pods | Where-Object { -not (Test-PodReady $_) -and (Get-OwnerKind $_) -ne 'Job' } | ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" })
if ($notReady) { Stop-Test "pods no longer Ready after convergence: $($notReady -join ', ')" }
$restartedDuringStartup = @($restartsAfter.Keys | Where-Object { $restartsAfter[$_] -gt 0 } | Sort-Object | ForEach-Object { "$_ x$($restartsAfter[$_])" })
Write-Host "Stable for $StableSeconds s. Restarts while converging (allowed): $(if ($restartedDuringStartup) { $restartedDuringStartup -join ', ' } else { 'none' })"

# --- 4. Smoke --------------------------------------------------------------------------------------------------------------------
Write-Step 'Test-Smoke.ps1'
& (Join-Path $PSScriptRoot 'Test-Smoke.ps1') -Environment $Environment
if ($LASTEXITCODE -ne 0) { Stop-Test 'smoke checks failed.' }

Write-Summary
Write-Host "`nFresh cluster converged on its own and passed the smoke checks." -ForegroundColor Green
exit 0
