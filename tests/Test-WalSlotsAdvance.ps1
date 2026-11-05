#Requires -Version 7.4
<#
.SYNOPSIS
    Idle replication slots do not hold back the WAL (plan 08 Task 1): Debezium's heartbeats move every slot, and Postgres caps what a
    stuck slot may keep.
.DESCRIPTION
    On the running local cluster `procure` (converged):
    1. Records every logical replication slot: its lag (pg_current_wal_lsn() - restart_lsn, the WAL Postgres must keep for it) and its
       wal_status, and the server's max_slot_wal_keep_size. Reports each Postgres Debezium pod's heartbeat interval
       (DEBEZIUM_SOURCE_HEARTBEAT_INTERVAL_MS); a pod without one fails the check.
    2. Writes -WalMB MB of WAL in an uncaptured scratch database (`walcheck_scratch`, created and dropped by the script; no slot reads it):
       non-transactional pg_logical_emit_message calls of 1 MB each. Without heartbeats nothing reaches the Debezium of an idle database,
       so its slot stays where it was and its lag grows by that much.
    3. Waits at most -IdleMinutes, polling every -HeartbeatMs (at least 5 s), until every slot's lag is below -MaxLagMB.
    4. Asserts: every slot's lag < -MaxLagMB, every slot's wal_status is `reserved`, and max_slot_wal_keep_size is not -1 (unlimited).
    The SQL runs with psql inside postgres-0 (kubectl exec, the pod's own credentials); nothing secret is printed. Exit code 1 on any failure.
.EXAMPLE
    ./tests/Test-WalSlotsAdvance.ps1 -IdleMinutes 20 -HeartbeatMs 10000
#>
[CmdletBinding()]
param(
    # How long the slots may take to catch up after the WAL was written.
    [int] $IdleMinutes = 20,
    # The heartbeat interval expected on the cluster; also the polling interval (at least 5 s).
    [int] $HeartbeatMs = 60000,
    [int] $WalMB = 200,
    [int] $MaxLagMB = 64,
    [double] $MinFreeGB = 3.5
)

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }
function Write-Step([string] $text) { Write-Host "`n== $(Get-Date -Format HH:mm:ss) $text" -ForegroundColor Cyan }

$scratch = 'walcheck_scratch'

function Invoke-Psql([string] $database, [string] $sql) {
    # The SQL is the shell's $2 (no quoting through kubectl); the password is the pod's own POSTGRES_PASSWORD.
    $out = & kubectl --context $KubeContext -n procure exec postgres-0 -c postgres -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -At -F "|" -c "$2"' sh $database $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql on $database failed: $($out -join ' ')" }
    @($out | ForEach-Object { "$_" } | Where-Object { $_ })
}

function Get-Slots {
    # slot name -> @{ LagMB; Status; Active } for every logical slot.
    $slots = [ordered]@{}
    $sql = "SELECT slot_name, round((pg_current_wal_lsn() - restart_lsn) / 1048576.0, 1), coalesce(wal_status, '(none)'), active " +
        "FROM pg_replication_slots WHERE slot_type = 'logical' ORDER BY 1"
    foreach ($row in Invoke-Psql 'postgres' $sql) {
        $f = $row -split '\|'
        $slots[$f[0]] = [pscustomobject]@{ LagMB = [decimal]::Parse($f[1], [cultureinfo]::InvariantCulture); Status = $f[2]; Active = $f[3] -eq 't' }
    }
    $slots
}

function Write-Slots($slots) {
    foreach ($name in $slots.Keys) {
        $s = $slots[$name]
        Write-Host ("  {0,-26} lag {1,8:N1} MB  wal_status {2,-9} active {3}" -f $name, $s.LagMB, $s.Status, $s.Active)
    }
}

function Assert-Memory {
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($free -lt $MinFreeGB) { throw ("Windows has only {0:N1} GB free memory (minimum {1} GB): stopping so the PC stays responsive." -f $free, $MinFreeGB) }
}

try {
    Assert-DockerRunning
    Assert-ClusterReachable
    Assert-Memory

    # --- 1. Before ----------------------------------------------------------------------------------------------------------------------
    Write-Step 'Replication slots, the WAL cap and the Debezium heartbeats'
    $keep = @(Invoke-Psql 'postgres' 'SHOW max_slot_wal_keep_size')[0]
    if ($keep -eq '-1') { Fail 'max_slot_wal_keep_size is -1: a stuck slot may hold back WAL without limit' }
    else { Pass "max_slot_wal_keep_size = $keep" }

    $pods = @((Invoke-Kubectl -n procure get pods -l procure.ai/debezium=true -o json | Out-String | ConvertFrom-Json).items |
            Where-Object { $_.metadata.name -ne 'debezium-mongo-0' })
    if ($pods.Count -eq 0) { Fail 'no Postgres Debezium pods found' }
    foreach ($pod in $pods) {
        $interval = $pod.spec.containers[0].env | Where-Object { $_.name -eq 'DEBEZIUM_SOURCE_HEARTBEAT_INTERVAL_MS' } |
            Select-Object -First 1 -ExpandProperty value
        if (-not $interval) { Fail "$($pod.metadata.name) has no heartbeat interval (DEBEZIUM_SOURCE_HEARTBEAT_INTERVAL_MS)" }
        else {
            Write-Host ("  {0,-26} heartbeat every {1} ms{2}" -f $pod.metadata.name, $interval,
                $(if ([int]$interval -gt $HeartbeatMs) { " (more than -HeartbeatMs $HeartbeatMs; the wait may need longer)" } else { '' }))
        }
    }

    $before = Get-Slots
    if ($before.Count -eq 0) { throw 'no logical replication slot found (is Debezium running?)' }
    Write-Slots $before

    # --- 2. WAL in a database no slot reads -----------------------------------------------------------------------------------------
    Write-Step "Writing $WalMB MB of WAL in the scratch database $scratch"
    if (-not (Invoke-Psql 'postgres' "SELECT 1 FROM pg_database WHERE datname = '$scratch'")) {
        Invoke-Psql 'postgres' "CREATE DATABASE $scratch" | Out-Null
    }
    $walStart = @(Invoke-Psql 'postgres' 'SELECT pg_current_wal_lsn()')[0]
    # Non-transactional logical messages go to the WAL at once; 1 MB each, in batches of 50 so no single call runs long.
    for ($written = 0; $written -lt $WalMB; $written += 50) {
        $n = [Math]::Min(50, $WalMB - $written)
        Invoke-Psql $scratch "SELECT count(pg_logical_emit_message(false, 'walcheck', repeat('x', 1048576))) FROM generate_series(1, $n)" | Out-Null
    }
    $grown = @(Invoke-Psql 'postgres' "SELECT round((pg_current_wal_lsn() - '$walStart'::pg_lsn) / 1048576.0, 1)")[0]
    Write-Host "  WAL grew by $grown MB"
    Write-Slots (Get-Slots)

    # --- 3. Wait until every slot has caught up ---------------------------------------------------------------------------------------
    $poll = [Math]::Max(5, [int][Math]::Ceiling($HeartbeatMs / 1000))
    $deadline = (Get-Date).AddMinutes($IdleMinutes)
    Write-Step "Waiting until every slot's lag is below $MaxLagMB MB (until $($deadline.ToString('HH:mm:ss')), polling every $poll s)"
    $started = Get-Date
    do {
        Start-Sleep -Seconds $poll
        Assert-Memory
        $now = Get-Slots
        $behind = @($now.Keys | Where-Object { $now[$_].LagMB -ge $MaxLagMB })
        Write-Host ("  {0:N0} s: {1} of {2} slot(s) behind{3}" -f ((Get-Date) - $started).TotalSeconds, $behind.Count, $now.Count,
            $(if ($behind) { " ($($behind -join ', '))" } else { '' }))
    } while ($behind -and (Get-Date) -lt $deadline)

    # --- 4. After -------------------------------------------------------------------------------------------------------------------
    Write-Step 'Slots after the wait'
    Write-Slots $now
    foreach ($name in $before.Keys) {
        if (-not $now.Contains($name)) { Fail "replication slot $name is gone" }
    }
    foreach ($name in $now.Keys) {
        $s = $now[$name]
        if ($s.LagMB -lt $MaxLagMB) { Pass ("{0}: lag {1:N1} MB (< {2} MB)" -f $name, $s.LagMB, $MaxLagMB) }
        else { Fail ("{0}: lag {1:N1} MB after {2} min (must be < {3} MB): the slot does not move while its database is idle" -f $name, $s.LagMB, $IdleMinutes, $MaxLagMB) }
        if ($s.Status -eq 'reserved') { Pass "${name}: wal_status reserved" }
        else { Fail "${name}: wal_status $($s.Status) (must be reserved)" }
    }
} catch {
    Fail "the check stopped: $_"
} finally {
    try {
        if (Invoke-Psql 'postgres' "SELECT 1 FROM pg_database WHERE datname = '$scratch'") {
            Invoke-Psql 'postgres' "DROP DATABASE $scratch" | Out-Null
            Write-Host "  dropped the scratch database $scratch"
        }
    } catch { Write-Host "  could not drop $scratch ($_)" -ForegroundColor Yellow }
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nEvery replication slot keeps up while its database is idle, and the WAL a slot may hold is capped." -ForegroundColor Green
exit 0
