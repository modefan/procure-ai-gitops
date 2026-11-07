#Requires -Version 7.4
<#
.SYNOPSIS
    Data survives restarts (plan 07 Review Focus 3): a cluster stop/start and deleted Postgres and MongoDB pods keep every row and every
    Debezium position, and the change capture still works afterwards.
.DESCRIPTION
    On the running local cluster `procure` (converged, e.g. after Test-FreshCluster.ps1 or a deploy):
    1. Counts, per tenant: purchase requests (requestsdb), business events and data changes (Audit's Marten documents in auditdb); the
       supplier documents (MongoDB suppliersdb); and each Debezium replication slot's confirmed position (pg_replication_slots). A slot
       must still exist afterwards; its position may be back at the last checkpoint after the unclean node stop (Postgres saves slot
       positions only at checkpoints and sends the changes since again), which the equal data change counts show to be harmless.
    2. `k3d cluster stop procure`, `k3d cluster start procure`, then waits until everything is converged again (Test-FreshCluster.ps1
       -WatchOnly: every Application Synced and Healthy, every pod Ready, nothing restarting, smoke checks).
    3. Deletes the postgres-0 and mongo-0 pods and waits again.
    4. Waits -SettleSeconds (a Debezium that lost its offset and snapshots again, or replays, would add data changes in that time), then
       compares: every count equal, every slot still there, every Debezium pod Ready with no restart
       since the wait.
    5. Creates a purchase request with the admin key and checks that its insert reaches the data change log (Debezium -> RabbitMQ -> Audit)
       within -CaptureSeconds, attributed to the app (not "outside the app").
    Counts are read with psql / mongosh inside the database pods (kubectl exec, the pods' own credentials); nothing secret is printed.
    The admin key (user env var DEMO_ADMIN_API_KEY) goes to curl in a header file only the current user can read. Exit code 1 on any failure.

    -Environment hosted -Reboot (plan 08 Review Focus 4): step 2 reboots the hosted VM instead (`sudo systemctl reboot` over SSH; the
    kubelet's graceful node shutdown stops the pods first), waits for SSH, reopens the tunnel and waits until the cluster has converged
    again (Test-FreshCluster.ps1 -Environment hosted -WatchOnly), which must happen within -ConvergeMinutes of the reboot. Postgres must
    have shut down cleanly: crash recovery in its log after the reboot FAILS (with k3d it is only reported: `k3d cluster stop` kills it).
    Hosted: the public host name, Let's Encrypt certificates (Windows' trusted roots) and the admin key from DEMO_ADMIN_API_KEY_HOSTED.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'hosted')]
    [string] $Environment = 'local',
    # Hosted only: reboot the VM (the only restart a hosted cluster has; required with -Environment hosted).
    [switch] $Reboot,
    [int] $ConvergeMinutes = 15,
    [string] $AppHost,
    [int] $SettleSeconds = 60,
    [int] $CaptureSeconds = 30,
    [double] $MinFreeGB = 3.5
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }
function Write-Step([string] $text) { Write-Host "`n== $(Get-Date -Format HH:mm:ss) $text" -ForegroundColor Cyan }

$curl = @('C:\Program Files\Git\mingw64\bin\curl.exe', "$env:SystemRoot\System32\curl.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $curl) { throw 'curl not found.' }
$hosted = $Environment -eq 'hosted'
if ($hosted -ne [bool] $Reboot) { throw '-Reboot goes with -Environment hosted (the local cluster restarts with k3d stop/start).' }
Select-ProcureCluster $Environment
if (-not $AppHost) { $AppHost = if ($hosted) { "procure.$HostedDomain" } else { 'procure.localtest.me' } }
$tlsArgs = @('--ssl-no-revoke')
if (-not $hosted) { $tlsArgs += @('--cacert', (Join-Path $LocalCaDir 'ca.crt')) }
$keyVar = if ($hosted) { 'DEMO_ADMIN_API_KEY_HOSTED' } else { 'DEMO_ADMIN_API_KEY' }
$key = [Environment]::GetEnvironmentVariable($keyVar, 'Process')
if (-not $key) { $key = [Environment]::GetEnvironmentVariable($keyVar, 'User') }
if (-not $key) { throw "User env var $keyVar is not set." }

function Invoke-Psql([string] $database, [string] $sql) {
    # The SQL is the shell's $1 (no quoting through kubectl); the password is the pod's own POSTGRES_PASSWORD.
    $out = & kubectl @KubectlArgs -n procure exec postgres-0 -c postgres -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -At -F "|" -c "$2"' sh $database $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql on $database failed: $($out -join ' ')" }
    @($out | ForEach-Object { "$_" } | Where-Object { $_ })
}

function Invoke-Mongo([string] $script) {
    $out = & kubectl @KubectlArgs -n procure exec mongo-0 -c mongo -- sh -c 'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --tls --tlsAllowInvalidCertificates --eval "$1"' sh $script 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mongosh failed: $($out -join ' ')" }
    @($out | ForEach-Object { "$_" } | Where-Object { $_ })
}

function Get-Counts {
    # name -> count, e.g. "requests acme" -> 18.
    $counts = [ordered]@{}
    foreach ($row in Invoke-Psql 'requestsdb' 'SELECT tenant_id, count(*) FROM purchase_requests GROUP BY 1 ORDER BY 1') {
        $f = $row -split '\|'; $counts["requests $($f[0])"] = [int64] $f[1]
    }
    $sql = "SELECT 'business events', coalesce(data->>'TenantId', '(none)'), count(*) FROM audit.mt_doc_businessevent GROUP BY 2 " +
        "UNION ALL SELECT 'data changes', coalesce(data->>'TenantId', '(none)'), count(*) FROM audit.mt_doc_datachange GROUP BY 2 ORDER BY 1, 2"
    foreach ($row in Invoke-Psql 'auditdb' $sql) {
        $f = $row -split '\|'; $counts["$($f[0]) $($f[1])"] = [int64] $f[2]
    }
    $suppliers = Invoke-Mongo 'print(db.getSiblingDB("suppliersdb").suppliers.countDocuments({}))'
    $counts['suppliers (MongoDB)'] = [int64] @($suppliers)[-1]
    $counts
}

function Get-Slots {
    # slot name -> confirmed_flush_lsn as a number (each Debezium Postgres connector has one logical slot).
    $slots = @{}
    foreach ($row in Invoke-Psql 'postgres' "SELECT slot_name, confirmed_flush_lsn - '0/0'::pg_lsn FROM pg_replication_slots WHERE slot_type = 'logical' ORDER BY 1") {
        $f = $row -split '\|'; $slots[$f[0]] = [decimal] $f[1]
    }
    $slots
}

function Wait-Converged([string] $why) {
    Write-Step "Waiting until the cluster has converged again ($why)"
    & (Join-Path $PSScriptRoot 'Test-FreshCluster.ps1') -Environment $Environment -WatchOnly -StableSeconds 60 -MinFreeGB $MinFreeGB
    if ($LASTEXITCODE -ne 0) { throw "the cluster did not converge after $why (Test-FreshCluster.ps1 -WatchOnly failed)." }
}

function Get-Prop($object, [string] $path) {
    foreach ($part in $path -split '\.') {
        if ($null -eq $object -or -not $object.PSObject.Properties[$part]) { return $null }
        $object = $object.$part
    }
    $object
}

function Get-Restarts($pod) { [int](@(Get-Prop $pod 'status.containerStatuses') | Where-Object { $_ } | Measure-Object restartCount -Sum).Sum }

function Get-DebeziumPods {
    $json = Invoke-Kubectl -n procure get pods -l procure.ai/debezium=true -o json | Out-String | ConvertFrom-Json
    @($json.items)
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-restart-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Set-CurrentUserOnlyAcl $work
try {
    if (-not $hosted) { Assert-DockerRunning }
    Assert-ClusterReachable

    # --- 1. Before ----------------------------------------------------------------------------------------------------------------------
    Write-Step 'Counting rows, documents and Debezium positions'
    $before = Get-Counts
    $slotsBefore = Get-Slots
    $before.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Key, $_.Value) }
    Write-Host "  replication slots: $($slotsBefore.Keys -join ', ')"
    if ($slotsBefore.Count -eq 0) { Fail 'no logical replication slot found (is Debezium running?)' }
    if (-not ($before.Keys | Where-Object { $_ -like 'requests *' })) { Fail 'no purchase requests to count (is the demo seed done?)' }

    # --- 2. Cluster stop and start (local) or VM reboot (hosted) ------------------------------------------------------------------------
    if ($hosted) {
        Write-Step 'Rebooting the hosted VM (sudo systemctl reboot)'
        $bootBefore = (Invoke-HostedSsh -Command 'cat /proc/sys/kernel/random/boot_id') -join ''
        $stoppedAt = [datetime]::UtcNow
        Invoke-HostedSsh -Command 'sudo systemctl reboot' -AllowFailure | Out-Null
        & (Join-Path $PSScriptRoot '..\bootstrap\hosted\open-tunnel.ps1') -Close | Out-Host
        $deadline = (Get-Date).AddMinutes(10)
        $bootAfter = $null
        while (-not $bootAfter -or $bootAfter -eq $bootBefore) {
            if ((Get-Date) -gt $deadline) { throw 'the VM did not come back over SSH within 10 minutes (Contabo panel / VNC).' }
            Start-Sleep -Seconds 10
            $bootAfter = (Invoke-HostedSsh -Command 'cat /proc/sys/kernel/random/boot_id' -AllowFailure) -join ''
            if ($LASTEXITCODE -ne 0 -or $bootAfter -notmatch '^[0-9a-f-]{36}$') { $bootAfter = $null }
        }
        Write-Host ("  the VM is back over SSH {0:N0} s after the reboot (new boot id)" -f ([datetime]::UtcNow - $stoppedAt).TotalSeconds)
        $deadline = (Get-Date).AddMinutes(5)
        while ($true) {
            try { & (Join-Path $PSScriptRoot '..\bootstrap\hosted\open-tunnel.ps1') | Out-Host; if (Test-ClusterReachable) { break } } catch { }
            if ((Get-Date) -gt $deadline) { throw 'the Kubernetes API did not answer through the tunnel within 5 minutes of SSH coming back.' }
            Start-Sleep -Seconds 10
        }
        Wait-Converged 'the VM reboot'
        $took = [datetime]::UtcNow - $stoppedAt
        if ($took.TotalMinutes -le $ConvergeMinutes) { Pass ("the cluster converged on its own {0:mm\:ss} after the reboot (limit {1} min)" -f $took, $ConvergeMinutes) }
        else { Fail ("the cluster converged only {0:mm\:ss} after the reboot (limit {1} min)" -f $took, $ConvergeMinutes) }
    } else {
        Write-Step "k3d cluster stop $ClusterName"
        $stoppedAt = [datetime]::UtcNow
        & k3d cluster stop $ClusterName
        if ($LASTEXITCODE -ne 0) { throw 'k3d cluster stop failed.' }
        Write-Step "k3d cluster start $ClusterName"
        & k3d cluster start $ClusterName
        if ($LASTEXITCODE -ne 0) { throw 'k3d cluster start failed.' }
        $deadline = (Get-Date).AddMinutes(3)
        while (-not (Test-ClusterReachable)) {
            if ((Get-Date) -gt $deadline) { throw 'the API server did not come back within 3 minutes.' }
            Start-Sleep -Seconds 5
        }
        Wait-Converged 'the cluster restart'
    }
    # For the record: did Postgres shut down cleanly with the node, or recover from its WAL (then slot positions fall back to the last checkpoint)?
    $pgLog = & kubectl @KubectlArgs -n procure logs postgres-0 -c postgres --tail 400 2>&1
    # Only lines written since the stop (the log can hold older lines): they start with "yyyy-MM-dd HH:mm:ss.fff UTC".
    $recovered = @($pgLog | Where-Object {
            "$_" -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ UTC .*(not properly shut down|was interrupted|automatic recovery)' -and
            [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) -ge $stoppedAt.AddSeconds(-1) })
    Write-Host "  Postgres after the cluster start: $(if ($recovered) { "crash recovery from the WAL ($("$($recovered[0])".Trim()))" } else { 'clean start' })"
    if ($hosted) {
        # Review Focus 4: the kubelet's graceful node shutdown gives Postgres its grace period, so it must not recover from the WAL.
        # Only lines written after the reboot (the log can hold an earlier start): "yyyy-MM-dd HH:mm:ss.fff UTC" timestamps.
        $startLines = @($pgLog | Where-Object {
                "$_" -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ UTC .*database system was shut down at' -and
                [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) -ge $stoppedAt.AddSeconds(-1) })
        if ($recovered) { Fail "Postgres recovered from the WAL after the reboot: it did not shut down cleanly ($("$($recovered[0])".Trim()))" }
        elseif (-not $startLines) { Fail 'the Postgres log shows no "database system was shut down at" start after the reboot (cannot tell a clean start)' }
        else { Pass "Postgres started cleanly after the reboot (no crash recovery): $("$($startLines[0])".Trim())" }
    }

    # --- 3. Database pods deleted ---------------------------------------------------------------------------------------------------
    Write-Step 'Deleting the postgres-0 and mongo-0 pods'
    Invoke-Kubectl -n procure delete pod postgres-0 mongo-0 --wait=true | ForEach-Object { Write-Host "  $_" }
    # The StatefulSets recreate them; give the controller a moment before the watch reads pod states.
    Start-Sleep -Seconds 10
    Wait-Converged 'deleting the database pods'

    # --- 4. After -------------------------------------------------------------------------------------------------------------------
    $debeziumBefore = @{}
    foreach ($pod in Get-DebeziumPods) { $debeziumBefore[$pod.metadata.name] = Get-Restarts $pod }
    Write-Step "Settling $SettleSeconds s (a lost Debezium offset would snapshot or replay in this time), then counting again"
    Start-Sleep -Seconds $SettleSeconds
    $after = Get-Counts
    $slotsAfter = Get-Slots
    foreach ($name in @($before.Keys) + @($after.Keys | Where-Object { -not $before.Contains($_) }) | Select-Object -Unique) {
        $b = if ($before.Contains($name)) { $before[$name] } else { 0 }
        $a = if ($after.Contains($name)) { $after[$name] } else { 0 }
        if ($a -eq $b) { Pass ("{0}: {1} before and after" -f $name, $b) } else { Fail ("{0}: {1} before, {2} after" -f $name, $b, $a) }
    }
    foreach ($slot in $slotsBefore.Keys) {
        if (-not $slotsAfter.ContainsKey($slot)) { Fail "replication slot $slot is gone" }
        elseif ($slotsAfter[$slot] -lt $slotsBefore[$slot]) {
            # Postgres saves a slot's position only at checkpoints: after an unclean stop (k3d stops the node without draining it) the slot is
            # back at its last checkpoint and the changes since are decoded again. Debezium resumes from its own offset and Audit stores a
            # change once by its log position, so nothing is lost or stored twice: the equal data change counts above check that.
            Pass "replication slot $slot kept; back at its last checkpointed position ($($slotsBefore[$slot]) -> $($slotsAfter[$slot])), changes since then are sent again and deduplicated"
        }
        else { Pass "replication slot $slot kept (position $($slotsBefore[$slot]) -> $($slotsAfter[$slot]))" }
    }
    $debeziumPods = Get-DebeziumPods
    if ($debeziumPods.Count -eq 0) { Fail 'no Debezium pods found' }
    foreach ($pod in $debeziumPods) {
        $ready = @(Get-Prop $pod 'status.conditions' | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        $restarts = Get-Restarts $pod
        $was = $debeziumBefore[$pod.metadata.name]
        if ($ready -and $restarts -eq $was) { Pass "$($pod.metadata.name) Ready, no restart while settling" }
        else { Fail "$($pod.metadata.name): Ready=$ready, restarts $was -> $restarts" }
    }

    # --- 5. A new change is captured ---------------------------------------------------------------------------------------------
    Write-Step "A new purchase request must reach the data change log within $CaptureSeconds s"
    $headers = Join-Path $work 'headers.txt'
    Set-Content -Path $headers -Value @("X-Api-Key: $key", 'X-Tenant-Id: acme', "Idempotency-Key: $([guid]::NewGuid())", 'Content-Type: application/json')
    $body = Join-Path $work 'request.json'
    @{ title = "Restart check $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"; costCenterCode = 'IT-200'; supplierId = 'contoso-hardware'
        lines = @(@{ sku = 'MON-27'; quantity = 1 }) } | ConvertTo-Json -Depth 5 | Set-Content -Path $body
    $response = Join-Path $work 'response.json'
    $status = & $curl -sS --max-time 20 @tlsArgs -o $response -w '%{http_code}' -H "@$headers" --data "@$body" "https://$AppHost/api/v1/requests" 2>&1
    if ("$status" -ne '201') { Fail "creating a request answered $status $(Get-Content -Raw $response -ErrorAction SilentlyContinue)" }
    else {
        $id = (Get-Content -Raw $response | ConvertFrom-Json).id
        Set-Content -Path $headers -Value @("X-Api-Key: $key", 'X-Tenant-Id: acme')
        $created = Get-Date
        $found = $null
        while (((Get-Date) - $created).TotalSeconds -lt $CaptureSeconds) {
            Start-Sleep -Seconds 2
            $status = & $curl -sS --max-time 10 @tlsArgs -o $response -w '%{http_code}' -H "@$headers" "https://$AppHost/api/v1/audit/requests/$id/data-changes" 2>&1
            if ("$status" -eq '200') {
                $page = Get-Content -Raw $response | ConvertFrom-Json
                $insert = @($page.items | Where-Object { $_.table -eq 'purchase_requests' -and $_.operation -eq 'Insert' -and $_.attribution -ne 'Pending' })
                if ($insert) { $found = $insert[0]; break }
            }
        }
        $after = ((Get-Date) - $created).TotalSeconds
        if (-not $found) { Fail "the new request $id did not reach the data change log within $CaptureSeconds s" }
        elseif ($found.attribution -eq 'OutsideApp') { Fail "the new request's insert reached the data change log as 'outside the app'" }
        else { Pass ("the new request's insert reached the data change log after {0:N0} s, attributed {1}" -f $after, $found.attribution) }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nData survived the restarts and the change capture still works." -ForegroundColor Green
exit 0
