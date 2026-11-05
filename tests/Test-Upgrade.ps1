#Requires -Version 7.4
<#
.SYNOPSIS
    An upgrade runs the migrations first, and a failing migration stops it (plan 07 Review Focus 2).
.DESCRIPTION
    On the running local cluster `procure`, converged at envs/<env>/release.yaml's appRevision:
    1. No-op revision: a throwaway procure-ai branch test-upgrade/noop-<stamp> (from -BaseRevision, default the release's appRevision) adds
       an empty Requests migration. Its requests-api image is built on the PC and imported into k3d; every other app image is the release's
       image tagged with the new revision inside the node (`ctr images tag`: the code is the same). The root Application's helm parameter
       appRevision points the Applications at it. Checks: every <name>-migrate Job is new (another UID), succeeded, and finished before the
       pods of its app started; every app Deployment runs the new revision; the empty migration is in Requests' migration history.
    2. Broken revision: test-upgrade/broken-<stamp> adds a Requests migration that raises an error, so `requests-api --migrate` exits 1.
       Checks: the new requests-migrate Job fails, and for -BrokenObserveSeconds the old requests-api pods keep running and serving (every app
       Deployment stays at the no-op revision), the procure-ai sync does not succeed, and within -DegradedWithinMinutes of the deploy (every
       retry spent: 3, apps/values.yaml) its last sync is Failed and the root Application is Degraded (plan 08 ruling 9).
    3. Always (also after a failure): the running sync is terminated, the root's parameter removed, and the script waits until everything is
       back at the release's appRevision; then the test migrations' history rows, the throwaway branches, the worktree and the test image
       tags are removed. Rerunnable: a parameter or branches left by an interrupted run are cleaned up first.
    Nothing secret is printed; the admin key (user env var DEMO_ADMIN_API_KEY) goes to curl in a header file only the current user can read.
    Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [string] $Environment = 'local',
    # The procure-ai clone to make the throwaway branches in (they are pushed to its origin, which Argo CD reads).
    [string] $AppRepo = (Join-Path $PSScriptRoot '..\..\procure-ai'),
    # The commit the test revisions start from. Default: the release's appRevision. Its images must be the ones running (they are
    # retagged for the test revisions), so only use another commit that changes no app code (e.g. tests, docs, charts).
    [string] $BaseRevision = '',
    [string] $AppHost = 'procure.localtest.me',
    [int] $DeployTimeoutMinutes = 20,
    [int] $BrokenObserveSeconds = 180,
    # The root must turn Degraded within this many minutes of the broken revision's deploy (plan 08 ruling 9).
    [int] $DegradedWithinMinutes = 5,
    [double] $MinFreeGB = 3.5
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppRepo = (Resolve-Path $AppRepo).Path
$registry = 'ghcr.io/modefan'
$appImages = @('access-api', 'approvals-api', 'assistant-api', 'audit-api', 'budgets-api', 'invoicing-api', 'notifications-api',
    'purchasing-api', 'requests-api', 'suppliers-api', 'gateway', 'simulators', 'demo-data', 'web')
$node = "k3d-$ClusterName-server-0"
$branchPrefix = 'test-upgrade/'

$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }
function Write-Step([string] $text) { Write-Host "`n== $(Get-Date -Format HH:mm:ss) $text" -ForegroundColor Cyan }
function Short([string] $sha) { if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { '(none)' } }

function Invoke-Git {
    $out = & git -C $AppRepo @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $($out -join ' ')" }
    $out | ForEach-Object { "$_" }
}

function Assert-Memory {
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($free -lt $MinFreeGB) { throw ("Windows has only {0:N1} GB free memory (minimum {1} GB): stopping so the PC stays responsive." -f $free, $MinFreeGB) }
}

function Get-App([string] $name) {
    Invoke-Kubectl -n argocd get application $name -o json | Out-String | ConvertFrom-Json
}

function Get-Prop($object, [string] $path) {
    # A nested property or $null (status fields come and go).
    foreach ($part in $path -split '\.') {
        if ($null -eq $object -or -not $object.PSObject.Properties[$part]) { return $null }
        $object = $object.$part
    }
    $object
}

function Get-RootRevisionParameter {
    $params = Get-Prop (Get-App 'root') 'spec.source.helm.parameters'
    if ($null -eq $params) { return $null }
    @($params | Where-Object { $_.name -eq 'appRevision' } | ForEach-Object { $_.value })[0]
}

function Set-RootRevision([string] $revision) {
    # A helm parameter of the root Application overrides release.yaml's appRevision (nobody manages the root itself, so Argo CD does
    # not undo it). Empty: remove it again, back to release.yaml.
    if ($revision) {
        $script:revisionChanged = $true
        $patch = @{ spec = @{ source = @{ helm = @{ parameters = @(@{ name = 'appRevision'; value = $revision }) } } } } | ConvertTo-Json -Depth 10 -Compress
        Invoke-Kubectl -n argocd patch application root --type merge -p $patch | Out-Null
    } elseif ($null -ne (Get-Prop (Get-App 'root') 'spec.source.helm.parameters')) {
        Invoke-Kubectl -n argocd patch application root --type json -p '[{"op":"remove","path":"/spec/source/helm/parameters"}]' | Out-Null
    }
    Invoke-Kubectl -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite | Out-Null
}

function Stop-RunningSync([string] $name) {
    # What `argocd app terminate-op` does: the controller stops a sync whose phase is Terminating (the Application CRD has no status
    # subresource, so a plain patch reaches it).
    $phase = Get-Prop (Get-App $name) 'status.operationState.phase'
    if ($phase -eq 'Running') {
        Invoke-Kubectl -n argocd patch application $name --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}' | Out-Null
        Write-Host "  terminated the running sync of $name"
    }
}

function Wait-Deployed([string] $revision, [datetimeoffset] $since) {
    # procure-ai: Synced and Healthy at $revision by a sync that finished after $since; platform (and observability): Synced at $revision
    # (an unchanged chart needs no new sync).
    $deadline = (Get-Date).AddMinutes($DeployTimeoutMinutes)
    $last = ''
    while ($true) {
        Assert-Memory
        $app = Get-App 'procure-ai'
        $synced = @(Get-Prop $app 'status.sync.revisions')[0]
        $opRevision = @(Get-Prop $app 'status.operationState.syncResult.revisions')[0]
        $phase = Get-Prop $app 'status.operationState.phase'
        $finished = Get-Prop $app 'status.operationState.finishedAt'
        $state = "procure-ai: $(Get-Prop $app 'status.sync.status') at $(Short $synced), health $(Get-Prop $app 'status.health.status'), last sync $phase at $(Short $opRevision)"
        $done = $synced -eq $revision -and $opRevision -eq $revision -and $phase -eq 'Succeeded' -and
            (Get-Prop $app 'status.sync.status') -eq 'Synced' -and (Get-Prop $app 'status.health.status') -eq 'Healthy' -and
            $finished -and ([datetimeoffset] $finished) -ge $since
        foreach ($other in 'platform', 'observability') {
            $o = & kubectl --context $KubeContext -n argocd get application $other -o json 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            $o = ($o | Out-String | ConvertFrom-Json)
            $r = @(Get-Prop $o 'status.sync.revisions')[0]
            $state += "; ${other}: $(Get-Prop $o 'status.sync.status') at $(Short $r)"
            if ($r -ne $revision -or (Get-Prop $o 'status.sync.status') -ne 'Synced') { $done = $false }
        }
        if ($done) { Write-Host "  $state"; return }
        if ($state -ne $last) { Write-Host "  $(Get-Date -Format HH:mm:ss) $state"; $last = $state }
        if ((Get-Date) -gt $deadline) { throw "not deployed at $(Short $revision) within $DeployTimeoutMinutes minutes ($state)." }
        Start-Sleep -Seconds 10
    }
}

function Get-MigrationJobs {
    $jobs = @{}
    foreach ($job in (Invoke-Kubectl -n procure get jobs -l app.kubernetes.io/component=migration -o json | Out-String | ConvertFrom-Json).items) {
        $jobs[$job.metadata.name] = [pscustomobject]@{
            Uid        = $job.metadata.uid
            Succeeded  = [int](Get-Prop $job 'status.succeeded')
            Failed     = [int](Get-Prop $job 'status.failed')
            Completion = if (Get-Prop $job 'status.completionTime') { [datetimeoffset] $job.status.completionTime } else { $null }
        }
    }
    $jobs
}

function Get-AppDeployments {
    # Deployment -> image tag and its pods (name, start, ready).
    $pods = (Invoke-Kubectl -n procure get pods -l app.kubernetes.io/component=app -o json | Out-String | ConvertFrom-Json).items
    $result = @{}
    foreach ($d in (Invoke-Kubectl -n procure get deployments -l app.kubernetes.io/component=app -o json | Out-String | ConvertFrom-Json).items) {
        $name = $d.metadata.name
        $image = $d.spec.template.spec.containers[0].image
        $mine = @($pods | Where-Object { $_.metadata.labels.'app.kubernetes.io/name' -eq $name -and -not (Get-Prop $_ 'metadata.deletionTimestamp') })
        $result[$name] = [pscustomobject]@{
            Tag   = $image.Substring($image.LastIndexOf(':') + 1)
            Pods  = @($mine | ForEach-Object {
                    [pscustomobject]@{
                        Name    = $_.metadata.name
                        Created = [datetimeoffset] $_.metadata.creationTimestamp
                        Ready   = @(Get-Prop $_ 'status.conditions' | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
                        Tag     = $_.spec.containers[0].image.Substring($_.spec.containers[0].image.LastIndexOf(':') + 1)
                    } })
        }
    }
    $result
}

function Invoke-Psql([string] $database, [string] $sql) {
    $out = & kubectl --context $KubeContext -n procure exec postgres-0 -c postgres -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -At -c "$2"' sh $database $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql on $database failed: $($out -join ' ')" }
    @($out | ForEach-Object { "$_" } | Where-Object { $_ })
}

function Copy-ImageTag([string] $from, [string] $to) {
    # The release's app images, tagged with a test revision inside the node's containerd (imagePullPolicy IfNotPresent uses them).
    foreach ($name in $appImages | Where-Object { $_ -ne 'requests-api' }) {
        $out = & docker exec $node ctr -n k8s.io images tag --force "$registry/procure-ai-${name}:$from" "$registry/procure-ai-${name}:$to" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tagging procure-ai-${name}:$(Short $from) as $(Short $to) in the node failed (is the release's image in the node?): $out" }
    }
}

function Remove-ImageTag([string] $tag) {
    foreach ($name in $appImages) {
        & docker exec $node ctr -n k8s.io images rm "$registry/procure-ai-${name}:$tag" 2>&1 | Out-Null
    }
    & docker image rm "$registry/procure-ai-requests-api:$tag" "procure-ai-requests-api:$tag" 2>&1 | Out-Null
}

function New-TestRevision([string] $worktree, [string] $branch, [string] $migrationId, [string] $className, [string] $up, [string] $message) {
    # Adds one Requests migration (no target model: the model does not change), commits, pushes the throwaway branch, builds requests-api
    # with the new commit as tag and imports it into k3d. Returns the commit.
    $file = Join-Path $worktree "src/Services/Requests/ProcureAi.Requests.Infrastructure/Migrations/$migrationId.cs"
    @"
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ProcureAi.Requests.Infrastructure.Migrations
{
    /// <summary>Test-Upgrade (procure-ai-gitops tests/Test-Upgrade.ps1), on a throwaway branch only: $message</summary>
    [DbContext(typeof(RequestsDbContext))]
    [Migration("$migrationId")]
    public partial class $className : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            $up
        }
    }
}
"@ | Set-Content -Path $file -Encoding utf8NoBOM
    & git -C $worktree add -- $file 2>&1 | Out-Null
    $out = & git -C $worktree -c user.name='Test-Upgrade' -c user.email='test-upgrade@procure.localtest.me' commit -q -m "Test-Upgrade: $message (throwaway)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git commit failed: $out" }
    $commit = (& git -C $worktree rev-parse HEAD).Trim()
    $out = & git -C $worktree push -q origin "HEAD:refs/heads/$branch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git push of $branch failed: $out" }
    Write-Host "  pushed $branch at $(Short $commit)"
    Assert-Memory
    & (Join-Path $worktree 'deploy/scripts/build-images.ps1') -Tag $commit -Registry $registry -Only requests-api -ImportTo $ClusterName | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "building requests-api at $(Short $commit) failed." }
    $commit
}

function Remove-TestBranches {
    $remote = Invoke-Git ls-remote --heads origin "$branchPrefix*"
    foreach ($line in $remote) {
        $ref = ($line -split '\s+')[1]
        Invoke-Git push -q origin --delete $ref | Out-Null
        Write-Host "  deleted remote branch $($ref.Replace('refs/heads/', ''))"
    }
}

function Test-ServesRequests {
    $key = [Environment]::GetEnvironmentVariable('DEMO_ADMIN_API_KEY', 'Process')
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable('DEMO_ADMIN_API_KEY', 'User') }
    $curl = @('C:\Program Files\Git\mingw64\bin\curl.exe', "$env:SystemRoot\System32\curl.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $headers = Join-Path $work 'headers.txt'
    Set-Content -Path $headers -Value @("X-Api-Key: $key", 'X-Tenant-Id: acme')
    $status = & $curl -sS --max-time 20 --ssl-no-revoke --cacert (Join-Path $LocalCaDir 'ca.crt') -o NUL -w '%{http_code}' -H "@$headers" "https://$AppHost/api/v1/requests?pageSize=1" 2>&1
    Remove-Item $headers -Force
    "$status"
}

$release = Get-Content -Raw (Join-Path $repoRoot "envs/$Environment/release.yaml")
if ($release -notmatch '(?m)^appRevision:\s*"?([0-9a-f]{40})"?\s*$') { throw "envs/$Environment/release.yaml has no full appRevision." }
$releaseRevision = $Matches[1]
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$worktree = Join-Path ([IO.Path]::GetTempPath()) "procure-test-upgrade-$stamp"
$work = Join-Path ([IO.Path]::GetTempPath()) "procure-test-upgrade-work-$stamp"
Set-CurrentUserOnlyAcl $work
$testRevisions = @()
# Set once the root points at a test revision: only then must the restore wait for a new sync (otherwise nothing changes).
$script:revisionChanged = $false

try {
    Assert-DockerRunning
    Assert-ClusterReachable

    # --- 0. Clean start ------------------------------------------------------------------------------------------------------------------
    Write-Step "Release revision $(Short $releaseRevision); cleaning up what an interrupted run may have left"
    if (Get-RootRevisionParameter) {
        Stop-RunningSync 'procure-ai'
        Set-RootRevision ''
        Write-Host '  removed a leftover appRevision parameter of the root Application'
    }
    Invoke-Git fetch -q origin | Out-Null
    Remove-TestBranches
    Wait-Deployed $releaseRevision ([datetimeoffset]::MinValue)
    $base = if ($BaseRevision) { (Invoke-Git rev-parse "$BaseRevision^{commit}").Trim() } else { $releaseRevision }
    $changed = @(Invoke-Git diff --name-only $releaseRevision $base -- src infra tools)
    if ($changed) { throw "the base $(Short $base) changes app code against the release ($($changed.Count) files under src, infra, tools): its images would not be the release's." }
    Invoke-Git worktree add -q --detach $worktree $base | Out-Null

    # --- 1. No-op migration -----------------------------------------------------------------------------------------------------------
    Write-Step "No-op revision: a throwaway branch from $(Short $base) with an empty Requests migration"
    $noopId = "${stamp}_TestUpgradeNoOp"
    $noop = New-TestRevision $worktree "${branchPrefix}noop-$stamp" $noopId 'TestUpgradeNoOp' '// Nothing: the revision only needs a migration to run.' 'an empty migration'
    $testRevisions += $noop
    Copy-ImageTag $releaseRevision $noop
    $jobsBefore = Get-MigrationJobs
    if ($jobsBefore.Count -eq 0) { throw 'no migration Jobs found (label app.kubernetes.io/component=migration).' }
    $since = [datetimeoffset]::Now
    Write-Step "Deploying $(Short $noop) (root parameter appRevision)"
    Set-RootRevision $noop
    Wait-Deployed $noop $since

    $jobsAfter = Get-MigrationJobs
    $deployments = Get-AppDeployments
    foreach ($name in $jobsBefore.Keys | Sort-Object) {
        $old = $jobsBefore[$name]; $new = $jobsAfter[$name]
        if (-not $new) { Fail "$name is gone after the deploy"; continue }
        if ($new.Uid -eq $old.Uid) { Fail "$name was not rerun (same UID $($new.Uid))"; continue }
        if ($new.Succeeded -lt 1 -or -not $new.Completion) { Fail "$name did not succeed"; continue }
        $app = $name -replace '-migrate$', '-api'
        $d = $deployments[$app]
        if (-not $d) { Pass "$name rerun (new UID) and succeeded (no Deployment $app)"; continue }
        $early = @($d.Pods | Where-Object { $_.Created -lt $new.Completion })
        if ($early) { Fail "$app pods started before $name finished: $(($early | ForEach-Object Name) -join ', ')" }
        else { Pass "$name rerun (new UID), finished $($new.Completion.ToLocalTime().ToString('HH:mm:ss')), before the $($d.Pods.Count) new $app pod(s) started" }
    }
    $failedBefore = $failures.Count
    foreach ($name in $deployments.Keys | Sort-Object) {
        $d = $deployments[$name]
        $stale = @($d.Pods | Where-Object { $_.Tag -ne $noop -or -not $_.Ready })
        if ($d.Tag -ne $noop -or $stale -or $d.Pods.Count -eq 0) { Fail "$name runs $(Short $d.Tag), pods: $(($d.Pods | ForEach-Object { "$($_.Name) $(Short $_.Tag) ready=$($_.Ready)" }) -join ', ')" }
    }
    if ($failures.Count -eq $failedBefore) { Pass "every app Deployment runs $(Short $noop), all pods Ready" }
    $history = Invoke-Psql 'requestsdb' "SELECT count(*) FROM `"__EFMigrationsHistory`" WHERE `"MigrationId`" = '$noopId'"
    if (@($history)[0] -eq '1') { Pass "the empty migration $noopId is in Requests' migration history" } else { Fail "the empty migration $noopId is not in Requests' migration history" }

    # --- 2. Broken migration ----------------------------------------------------------------------------------------------------------
    Write-Step 'Broken revision: a Requests migration that raises an error (requests-api --migrate exits 1)'
    $brokenId = "$((Get-Date).AddSeconds(1).ToString('yyyyMMddHHmmss'))_TestUpgradeBroken"
    $broken = New-TestRevision $worktree "${branchPrefix}broken-$stamp" $brokenId 'TestUpgradeBroken' `
        'migrationBuilder.Sql("DO $$ BEGIN RAISE EXCEPTION ''Test-Upgrade: this migration fails on purpose''; END $$;");' 'a migration that fails'
    $testRevisions += $broken
    Copy-ImageTag $releaseRevision $broken
    $before = Get-AppDeployments
    $requestsJobBefore = (Get-MigrationJobs)['requests-migrate'].Uid
    Write-Step "Deploying $(Short $broken)"
    $brokenSince = Get-Date
    Set-RootRevision $broken
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        Assert-Memory
        $job = (Get-MigrationJobs)['requests-migrate']
        if ($job -and $job.Uid -ne $requestsJobBefore -and $job.Failed -ge 1) { break }
        if ((Get-Date) -gt $deadline) { throw 'the broken requests-migrate Job did not fail within 10 minutes.' }
        Start-Sleep -Seconds 10
    }
    $failedPod = @((Invoke-Kubectl -n procure get pods -l job-name=requests-migrate -o json | Out-String | ConvertFrom-Json).items |
        Where-Object { (Get-Prop $_ 'status.phase') -eq 'Failed' })[0]
    $log = if ($failedPod) { (& kubectl --context $KubeContext -n procure logs $failedPod.metadata.name 2>&1) -join "`n" } else { '' }
    if ($log -match 'fails on purpose') { Pass "requests-migrate at $(Short $broken) failed with the migration's error" }
    else { Fail "requests-migrate failed, but its log does not show the test migration's error" }

    Write-Step "Watching $BrokenObserveSeconds s: the old pods must keep running and serving"
    $watchUntil = (Get-Date).AddSeconds($BrokenObserveSeconds)
    $moved = @()
    while ((Get-Date) -lt $watchUntil) {
        $now = Get-AppDeployments
        foreach ($name in $now.Keys) {
            if ($now[$name].Tag -ne $noop -or @($now[$name].Pods | Where-Object { $_.Tag -ne $noop }).Count -gt 0) { $moved += $name }
        }
        $old = @($before['requests-api'].Pods | ForEach-Object Name)
        $current = @($now['requests-api'].Pods | Where-Object { $_.Ready } | ForEach-Object Name)
        if (@($old | Where-Object { $current -notcontains $_ }).Count -gt 0) { $moved += 'requests-api (old pod gone or not Ready)' }
        Start-Sleep -Seconds 15
    }
    $moved = @($moved | Select-Object -Unique)
    if ($moved) { Fail "Deployments changed although the migration failed: $($moved -join ', ')" }
    else { Pass "every app Deployment stayed at $(Short $noop); the old requests-api pod(s) $(($before['requests-api'].Pods | ForEach-Object Name) -join ', ') kept running, Ready" }
    $status = Test-ServesRequests
    if ($status -eq '200') { Pass 'GET /api/v1/requests (admin key) answers 200: the old Requests pods serve' } else { Fail "GET /api/v1/requests answered $status" }
    # Argo CD 3 keeps the health of an Application's resources out of its status (only in its cache), so the root's own health, which
    # aggregates its Applications' health from the check in argocd/values.yaml, is what shows: Progressing while procure-ai's sync is
    # retried, Degraded once every retry is spent (phase Failed).
    $degradedBy = $brokenSince.AddMinutes($DegradedWithinMinutes)
    $lastRoot = ''
    while ($true) {
        Assert-Memory
        $app = Get-App 'procure-ai'
        $phase = Get-Prop $app 'status.operationState.phase'; $message = Get-Prop $app 'status.operationState.message'
        $health = Get-Prop $app 'status.health.status'; $sync = Get-Prop $app 'status.sync.status'
        $root = Get-App 'root'
        $rootHealth = Get-Prop $root 'status.health.status'
        $rootMessage = Get-Prop $root 'status.health.message'
        $line = "procure-ai: sync $sync, health $health, last sync $phase; the root Application: $rootHealth"
        if ($line -ne $lastRoot) { Write-Host "  $(Get-Date -Format HH:mm:ss) $line"; $lastRoot = $line }
        if ($rootHealth -eq 'Degraded' -or (Get-Date) -gt $degradedBy) { break }
        Start-Sleep -Seconds 5
    }
    $after = [math]::Round(((Get-Date) - $brokenSince).TotalSeconds)
    Write-Host "  procure-ai's last sync: $phase ($message); the root: $rootHealth $rootMessage"
    if ($phase -eq 'Succeeded' -and @(Get-Prop $app 'status.operationState.syncResult.revisions')[0] -eq $broken) { Fail 'the procure-ai sync of the broken revision succeeded' }
    else { Pass "the procure-ai sync of $(Short $broken) did not succeed (phase $phase)" }
    if ($rootHealth -ne 'Degraded') { Fail "the root Application is '$rootHealth' $DegradedWithinMinutes minutes after the broken deploy (expected Degraded)" }
    else { Pass "the root Application turned Degraded $after s after the broken deploy (limit $DegradedWithinMinutes min)" }
} catch {
    Fail "$($_.Exception.Message)"
} finally {
    # --- 3. Restore -------------------------------------------------------------------------------------------------------------------
    Write-Step "Restoring the release revision $(Short $releaseRevision)"
    try {
        Stop-RunningSync 'procure-ai'
        $since = if ($script:revisionChanged) { [datetimeoffset]::Now } else { [datetimeoffset]::MinValue }
        Set-RootRevision ''
        Wait-Deployed $releaseRevision $since
        $back = Get-AppDeployments
        $wrong = @($back.Keys | Where-Object { $back[$_].Tag -ne $releaseRevision -or @($back[$_].Pods | Where-Object { $_.Tag -ne $releaseRevision -or -not $_.Ready }).Count -gt 0 })
        if ($wrong) { Fail "after the restore not at $(Short $releaseRevision): $($wrong -join ', ')" } else { Pass "back at $(Short $releaseRevision), every app pod Ready" }
        $removed = Invoke-Psql 'requestsdb' "DELETE FROM `"__EFMigrationsHistory`" WHERE `"MigrationId`" LIKE '%TestUpgrade%' RETURNING `"MigrationId`""
        if ($removed) { Write-Host "  removed the test migrations' history rows: $($removed -join ', ')" }
    } catch {
        Fail "restore: $($_.Exception.Message)"
    }
    try { Remove-TestBranches } catch { Fail "removing the throwaway branches: $($_.Exception.Message)" }
    if (Test-Path $worktree) {
        & git -C $AppRepo worktree remove --force $worktree 2>&1 | Out-Null
        if (Test-Path $worktree) { Remove-Item -Recurse -Force $worktree -ErrorAction SilentlyContinue }
    }
    & git -C $AppRepo worktree prune 2>&1 | Out-Null
    foreach ($revision in $testRevisions) { Remove-ImageTag $revision }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nUpgrades run the migrations first and a failing migration stops the rollout." -ForegroundColor Green
exit 0
