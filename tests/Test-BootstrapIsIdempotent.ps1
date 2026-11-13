#Requires -Version 7.4
<#
.SYNOPSIS
    Checks the cluster bootstrap after new-cluster.ps1, new-local-ca.ps1 and new-secrets.ps1 have run once.
.DESCRIPTION
    1. A second run of new-local-ca.ps1 and new-secrets.ps1 changes nothing: every object they manage (label
       app.kubernetes.io/managed-by=procure-bootstrap) keeps its resourceVersion (server-side apply reports no "unchanged"), and the
       CA files keep their hashes. No Secret in procure or observability carries the last-applied-configuration annotation
       (client-side apply would copy the Secret's data into it).
    1b. new-secrets.ps1 keeps a key it no longer writes (merge, the default) and removes it only with -Prune: a key written by the
       script's own field manager is added to procure-redis (the shape an older revision of the script left), a normal run must keep it
       with its value, a -Prune run must remove it and leave every other key as it was (plan 08 Task 6).
    2. Every Secret (with its keys), the procure-ca ConfigMap, the default TLSStore and the namespaces exist.
    3. A pod in `procure` resolves auth.procure.localtest.me to the Traefik ClusterIP (CoreDNS rewrite).
    4. Traefik serves the local CA's wildcard certificate on https://procure.localtest.me (port 443 on the PC).
    0. (first) The node is capped at 8 CPUs and the kubelet keeps memory back (reservations + eviction threshold) from what k3d gives it,
       and the cluster's published ports (80, 443, the API) listen on 127.0.0.1 / ::1 only, never on the PC's network interfaces.
    Prints names only, never values. Exit code 1 on any failure.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap'
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

if (-not (Test-ClusterReachable)) {
    Fail "cluster '$ClusterName' is not reachable (context $KubeContext); run bootstrap/new-cluster.ps1, new-local-ca.ps1, new-secrets.ps1 first"
    exit 1
}

# --- 0. Node budget: 8 CPUs, kubelet reservations and eviction (new-cluster.ps1) ------------------------------------------------------
$budget = Get-NodeBudget
if ($budget.Cpus -ne $NodeCpus) { Fail "node CPUs $($budget.Cpus), expected $NodeCpus (docker update --cpus)" } else { Pass "node capped at $NodeCpus CPUs" }
$keptBack = $budget.MemoryCapacity - $budget.MemoryAllocatable
if ($budget.MemoryCapacity -gt 10.5GB) { Fail "kubelet sees $([math]::Round($budget.MemoryCapacity / 1GB, 2)) GiB, not the node's $NodeMemory cap" }
if ($keptBack -lt (Get-ExpectedKeptBack)) { Fail "kubelet keeps back $([math]::Round($keptBack / 1MB)) MiB, expected $([math]::Round((Get-ExpectedKeptBack) / 1MB)) MiB" }
else { Pass "kubelet keeps back $([math]::Round($keptBack / 1MB)) MiB of $([math]::Round($budget.MemoryCapacity / 1GB, 2)) GiB (reserved + eviction-hard)" }

# Loopback only (final review I1): nobody on the LAN reaches Mailpit, Keycloak's admin console or Argo CD.
$exposure = @(Get-ClusterPortExposure)
if ($exposure) { foreach ($line in $exposure) { Fail "published port not on loopback only: $line" } }
else { Pass "ports $($PublishedPorts -join ', ') listen on 127.0.0.1 / ::1 only (docker bindings and Windows listeners)" }

# --- 1. Second run changes nothing -------------------------------------------------------------------------------------------------
$caFiles = @('ca.key', 'ca.crt', 'procure.key', 'procure.crt', 'mongo.key', 'mongo.crt', 'mongo.pem')
function Get-CaHashes {
    $hashes = [ordered]@{}
    foreach ($file in $caFiles) {
        $path = Join-Path $LocalCaDir $file
        $hashes[$file] = if (Test-Path $path) { (Get-FileHash $path -Algorithm SHA256).Hash } else { '<missing>' }
    }
    $hashes
}
$before = Get-CaHashes
foreach ($file in $caFiles) { if ($before[$file] -eq '<missing>') { Fail "CA file $file is missing in $LocalCaDir" } }

$managedKinds = 'secrets,configmaps,tlsstores.traefik.io'
function Get-ManagedVersions {
    $versions = [ordered]@{}
    foreach ($ns in 'procure', 'observability') {
        $json = & kubectl --context $KubeContext -n $ns get $managedKinds -l app.kubernetes.io/managed-by=procure-bootstrap -o json 2>$null
        if ($LASTEXITCODE -ne 0) { Fail "kubectl get $managedKinds in $ns failed"; continue }
        foreach ($item in ($json | ConvertFrom-Json -AsHashtable).items) {
            $versions["$($item.kind)/$ns/$($item.metadata.name)"] = $item.metadata.resourceVersion
        }
    }
    $versions
}
$versionsBefore = Get-ManagedVersions
# 12 Secrets (9 from new-secrets.ps1 in procure plus observability/procure-keycloak, procure-tls and mongo-tls), the TLSStore and
# procure-ca in two namespaces.
if ($versionsBefore.Count -lt 15) { Fail "expected at least 15 bootstrap-managed objects, found $($versionsBefore.Count)" }

$applied = 0
foreach ($script in 'new-local-ca.ps1', 'new-secrets.ps1') {
    try {
        $output = & (Join-Path $bootstrap $script) 6>&1 2>&1 | ForEach-Object { "$_" }
    } catch {
        Fail "second run of $script threw: $($_.Exception.Message)"
        continue
    }
    $lines = @($output | Where-Object { $_ -match '^\S+/\S+ serverside-applied' })
    if ($lines.Count -eq 0) { Fail "second run of $script applied no objects (expected server-side apply result lines)" }
    $applied += $lines.Count
    $output | Where-Object { $_ -match 'annotation .* removed' } | ForEach-Object { Fail "second run of ${script} still had to migrate: $_" }
}
$versionsAfter = Get-ManagedVersions
$changed = @($versionsBefore.Keys | Where-Object { $versionsAfter[$_] -ne $versionsBefore[$_] })
$added = @($versionsAfter.Keys | Where-Object { -not $versionsBefore.Contains($_) })
if ($changed -or $added) {
    $changed | ForEach-Object { Fail "second run changed $_ (resourceVersion $($versionsBefore[$_]) -> $($versionsAfter[$_]))" }
    $added | ForEach-Object { Fail "second run created $_" }
} else {
    Pass "second run: $applied applies, all $($versionsBefore.Count) managed objects kept their resourceVersion"
}

foreach ($ns in 'procure', 'observability') {
    $json = & kubectl --context $KubeContext -n $ns get secrets -o json 2>$null
    $annotated = @(($json | ConvertFrom-Json -AsHashtable).items | Where-Object {
        $_.metadata.ContainsKey('annotations') -and $_.metadata.annotations -and
        $_.metadata.annotations.ContainsKey('kubectl.kubernetes.io/last-applied-configuration') } | ForEach-Object { $_.metadata.name })
    if ($annotated) { Fail "secrets in $ns carry last-applied-configuration: $($annotated -join ', ')" }
    else { Pass "no secret in $ns carries last-applied-configuration" }
}

$after = Get-CaHashes
foreach ($file in $caFiles) {
    if ($before[$file] -ne $after[$file]) { Fail "CA file $file changed on the second run" }
}
if (-not ($caFiles | Where-Object { $before[$_] -ne $after[$_] })) { Pass 'CA files kept their hashes' }

# --- 1b. Stale keys: kept by default, removed with -Prune ---------------------------------------------------------------------------
# The key is applied server-side by the bootstrap's own field manager with every live key of the Secret, exactly as a run of an older
# new-secrets.ps1 that still wrote it would have left it; so a plain run of the script would remove it if it did not merge. Values never
# leave this process; only key names are printed.
$staleKey = 'stale-check'
function Get-SecretData([string] $name) {
    $json = & kubectl --context $KubeContext -n procure get secret $name -o json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    ($json | Out-String | ConvertFrom-Json -AsHashtable).data
}
$redisBefore = Get-SecretData 'procure-redis'
if (-not $redisBefore) { Fail 'secret procure/procure-redis is missing (stale-key check skipped)' }
else {
    $withStale = [ordered]@{}
    foreach ($key in $redisBefore.Keys) { $withStale[$key] = $redisBefore[$key] }
    $withStale[$staleKey] = ConvertTo-Base64 'written by an older bootstrap'
    try {
        Invoke-ServerSideApply -Json ((New-SecretObject -Namespace procure -Name procure-redis -EncodedData $withStale) | ConvertTo-Json -Depth 20 -Compress) `
            -Description 'Secret procure-redis with a stale key' | Out-Null
        $output = & (Join-Path $bootstrap 'new-secrets.ps1') 6>&1 2>&1 | ForEach-Object { "$_" }
        $merged = Get-SecretData 'procure-redis'
        if ($merged[$staleKey] -ne $withStale[$staleKey]) { Fail "a normal new-secrets.ps1 run removed or changed the stale key $staleKey (it must keep keys the live pods may still use)" }
        elseif (-not ($output | Where-Object { $_ -match "procure-redis.*stale key\(s\) kept.*$staleKey" })) { Fail "new-secrets.ps1 kept $staleKey but did not report it" }
        else { Pass "a normal run keeps the stale key $staleKey with its value and reports it" }
        $output = & (Join-Path $bootstrap 'new-secrets.ps1') -Prune 6>&1 2>&1 | ForEach-Object { "$_" }
        $pruned = Get-SecretData 'procure-redis'
        $otherKeysSame = @($redisBefore.Keys | Where-Object { $pruned[$_] -ne $redisBefore[$_] }).Count -eq 0
        if ($pruned.Contains($staleKey)) { Fail "new-secrets.ps1 -Prune did not remove the stale key $staleKey" }
        elseif (@($pruned.Keys).Count -ne @($redisBefore.Keys).Count -or -not $otherKeysSame) { Fail "new-secrets.ps1 -Prune changed procure-redis beyond the stale key (keys now: $(@($pruned.Keys) -join ', '))" }
        elseif (-not ($output | Where-Object { $_ -match "procure-redis.*stale key\(s\) pruned.*$staleKey" })) { Fail "new-secrets.ps1 -Prune removed $staleKey but did not report it" }
        else { Pass "-Prune removes the stale key $staleKey and leaves procure-redis's own keys as they were" }
    } catch {
        Fail "stale-key check: $($_.Exception.Message)"
    } finally {
        # Never leave the test key behind (a failed check, an interrupted run).
        $after = Get-SecretData 'procure-redis'
        if ($after -and $after.Contains($staleKey)) {
            $restore = [ordered]@{}
            foreach ($key in $redisBefore.Keys) { $restore[$key] = $redisBefore[$key] }
            Invoke-ServerSideApply -Json ((New-SecretObject -Namespace procure -Name procure-redis -EncodedData $restore) | ConvertTo-Json -Depth 20 -Compress) `
                -Description 'Secret procure-redis without the stale key' | Out-Null
        }
    }
}

# --- 2. Objects and keys exist ----------------------------------------------------------------------------------------------------
foreach ($ns in $Namespaces) {
    & kubectl --context $KubeContext get namespace $ns -o name 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "namespace $ns is missing" } else { Pass "namespace $ns" }
}

$expectedSecrets = [ordered]@{
    'procure-postgres'           = @('password')
    'procure-rabbitmq'           = @('username', 'password', 'operator-password')
    'procure-redis'              = @('password', 'operator-reader-password')
    'procure-mongo'              = @('username', 'password', 'keyfile')
    'procure-keycloak'           = @('admin-username', 'admin-password', 'demo-password', 'gateway-secret', 'internal-secret',
                                     'access-admin-secret', 'demo-login-secret', 'dashboard-secret', 'db-password',
                                     'operator-password', 'operator-totp-base32', 'automation-client-secret')
    'procure-debezium'           = @('mongo-password')
    'procure-db-roles'           = @('access-password', 'approvals-password', 'assistant-password', 'audit-password', 'budgets-password',
                                     'invoicing-password', 'purchasing-password', 'requests-password', 'suppliers-password',
                                     'access-cdc-password', 'approvals-cdc-password', 'assistant-cdc-password', 'budgets-cdc-password',
                                     'invoicing-cdc-password', 'purchasing-cdc-password', 'requests-cdc-password',
                                     'assistant-mongo-password', 'audit-log-reader-password')
    'procure-api-keys'           = @('admin-api-key', 'admin-api-key-sha256', 'simulator-api-key', 'supplier-webhook-secret')
    'procure-connection-strings' = @('requestsdb', 'accessdb', 'budgetsdb', 'approvalsdb', 'auditdb', 'purchasingdb', 'invoicingdb',
                                     'assistantdb', 'suppliersdb', 'assistantchatdb', 'rabbitmq', 'redis', 'auditlog')
    'procure-tls'                = @('tls.crt', 'tls.key')
    'mongo-tls'                  = @('tls.crt', 'tls.key', 'ca.crt', 'mongo.pem')
}
foreach ($name in $expectedSecrets.Keys) {
    $json = & kubectl --context $KubeContext -n procure get secret $name -o json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "secret procure/$name is missing"; continue }
    $secret = $json | ConvertFrom-Json -AsHashtable
    $keys = @($secret.data.Keys)
    $missing = @($expectedSecrets[$name] | Where-Object { $_ -notin $keys })
    $empty = @($expectedSecrets[$name] | Where-Object { $_ -in $keys -and [string]::IsNullOrEmpty($secret.data[$_]) })
    if ($missing) { Fail "secret procure/$name lacks keys: $($missing -join ', ')" }
    elseif ($empty) { Fail "secret procure/$name has empty keys: $($empty -join ', ')" }
    else { Pass "secret procure/$name ($($expectedSecrets[$name].Count) keys)" }
}
# The Aspire dashboard's copy in observability holds its own client secret and nothing else.
$json = & kubectl --context $KubeContext -n observability get secret procure-keycloak -o json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'secret observability/procure-keycloak is missing' }
else {
    $data = ($json | ConvertFrom-Json -AsHashtable).data
    $keys = @($data.Keys)
    if ($keys.Count -ne 1 -or $keys[0] -ne 'dashboard-secret' -or [string]::IsNullOrEmpty($data['dashboard-secret'])) {
        Fail "secret observability/procure-keycloak must hold only a non-empty dashboard-secret (has: $($keys -join ', '))"
    } else { Pass 'secret observability/procure-keycloak (dashboard-secret only)' }
}
# No GHCR pull Secret any more (the packages are public, plan 08c final review M5): the bootstrap removes the one older runs created.
$ghcrPull = & kubectl --context $KubeContext -n procure get secret ghcr-pull --ignore-not-found -o name 2>&1
if ($LASTEXITCODE -ne 0) { Fail "could not look up secret procure/ghcr-pull: $ghcrPull" }
elseif ($ghcrPull) { Fail 'secret procure/ghcr-pull still exists (the bootstrap must remove it; the GHCR packages are public)' }
else { Pass 'no secret procure/ghcr-pull (the GHCR packages are public)' }

$caHash = (& (Get-OpenSsl) x509 -subject_hash -noout -in (Join-Path $LocalCaDir 'ca.crt')).Trim()
foreach ($ns in 'procure', 'observability') {
    $json = & kubectl --context $KubeContext -n $ns get configmap procure-ca -o json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "configmap $ns/procure-ca is missing"; continue }
    $keys = @(($json | ConvertFrom-Json -AsHashtable).data.Keys)
    if ("$caHash.0" -notin $keys) { Fail "configmap $ns/procure-ca lacks key $caHash.0 (has: $($keys -join ', '))" }
    else { Pass "configmap $ns/procure-ca has $caHash.0" }
}
$store = & kubectl --context $KubeContext -n procure get tlsstores.traefik.io default -o jsonpath='{.spec.defaultCertificate.secretName}' 2>$null
if ($store -ne 'procure-tls') { Fail "TLSStore procure/default does not point at procure-tls (got '$store')" } else { Pass 'TLSStore default -> procure-tls' }

# --- 3. CoreDNS rewrite -----------------------------------------------------------------------------------------------------------
$traefikIp = & kubectl --context $KubeContext -n kube-system get service traefik -o jsonpath='{.spec.clusterIP}' 2>$null
if (-not $traefikIp) {
    Fail 'service kube-system/traefik not found'
} else {
    $pod = 'dns-check-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $resolved = $null
    # CoreDNS picks up a changed coredns-custom ConfigMap within a minute or so; allow for that.
    for ($i = 0; $i -lt 6 -and -not $resolved; $i++) {
        $out = & kubectl --context $KubeContext -n procure run $pod --image=busybox:1.37.0 --restart=Never --rm -i --quiet `
            --command -- nslookup auth.procure.localtest.me 2>&1 | ForEach-Object { "$_" }
        $addresses = @($out | Select-String -Pattern 'Address:\s*(\d+\.\d+\.\d+\.\d+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        # The first Address line is the DNS server itself; the answer follows.
        if ($addresses -contains $traefikIp) { $resolved = $traefikIp }
        elseif ($i -lt 5) { Start-Sleep -Seconds 10 }
    }
    & kubectl --context $KubeContext -n procure delete pod $pod --ignore-not-found --wait=false 2>&1 | Out-Null
    if ($resolved) { Pass "auth.procure.localtest.me resolves to Traefik ($traefikIp) inside the cluster" }
    else { Fail "auth.procure.localtest.me did not resolve to the Traefik ClusterIP $traefikIp from a pod in procure (last output: $($out -join ' | '))" }
}

# --- 4. Traefik serves the local CA's certificate ---------------------------------------------------------------------------------
# openssl, not .NET's SslStream: ESET on this PC intercepts TLS from some processes (pwsh among them) and presents its own
# "The original certificate provided by the server is untrusted" certificate instead of the server's.
$openssl = Get-OpenSsl
$ca = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $LocalCaDir 'ca.crt'))
$handshake = '' | & $openssl s_client -connect 127.0.0.1:443 -servername procure.localtest.me -CAfile (Join-Path $LocalCaDir 'ca.crt') `
    -verify_hostname procure.localtest.me -verify_return_error 2>&1 | ForEach-Object { "$_" }
$verify = $handshake | Select-String -Pattern 'Verify return code: (\d+)' | Select-Object -First 1
$issuer = $handshake | Select-String -Pattern '^issuer=(.*)$' | Select-Object -First 1
if ($verify -and $verify.Matches[0].Groups[1].Value -eq '0') {
    Pass "Traefik serves the wildcard certificate of '$($ca.Subject)' (verified against the local CA)"
} else {
    Fail "Traefik's certificate for procure.localtest.me does not verify against the local CA (issuer: $($issuer.Line), $($verify.Line))"
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll bootstrap checks passed." -ForegroundColor Green
exit 0
