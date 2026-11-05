# Shared by the bootstrap scripts and tests (dot-sourced). Nothing here prints a secret value: objects are built in memory and
# piped to `kubectl apply -f -`, whose output names the object only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:ClusterName = 'procure'
$script:KubeContext = "k3d-$script:ClusterName"
# Pinned k3s image (the default of k3d 5.9.0). Change it here and recreate the cluster to move to a new Kubernetes version.
$script:K3sImage = 'rancher/k3s:v1.35.5-k3s1'
$script:Namespaces = @('procure', 'observability', 'argocd')
# The node's budget (CLAUDE.md "My PC is shared"): memory capped by k3d (--servers-memory), CPUs by `docker update --cpus` on every
# run of new-cluster.ps1. The kubelet keeps memory back for k3s itself (API server, kubelet, containerd run in the node's process)
# and evicts pods when less than EvictionHard is free, so a memory-hungry workload loses pods instead of starving the control plane.
# Measured (plan 07 Task 5): with ~1 GiB still "available" to the kubelet (working set 8.98 of 10 GiB) the API server already timed out,
# so pods are evicted below 1 GiB free.
$script:NodeMemory = '10g'
$script:NodeCpus = 8
$script:KubeReservedMemory = '1Gi'
$script:SystemReservedMemory = '256Mi'
$script:EvictionHardMemory = '1Gi'
# Published on the PC's loopback address only (final review I1): Mailpit, Keycloak's admin console and Argo CD are not meant for a network,
# so the ingress (80/443) and the Kubernetes API never listen on the PC's network interfaces. A fixed API port keeps the kubeconfig stable.
$script:LoopbackAddress = '127.0.0.1'
$script:ApiPort = 6550
$script:PublishedPorts = @(80, 443, $script:ApiPort)
# Outside every repo; listed by name in DEMO PASSWORDS.txt.
$script:LocalCaDir = Join-Path $env:USERPROFILE '.procure-ai\local-ca'
# Argo CD's read-only deploy keys and CI's write key for this repo (plan 07 ruling 6); outside every repo, listed by name in DEMO
# PASSWORDS.txt.
$script:DeployKeyDir = Join-Path $env:USERPROFILE '.procure-ai\deploy-keys'
# The AppHost's UserSecretsId (src/AppHost/ProcureAi.AppHost/ProcureAi.AppHost.csproj): the one source of the secrets.
$script:AppHostUserSecretsId = 'procure-ai-apphost'

function Invoke-Kubectl {
    # kubectl against the procure cluster only, never whatever context happens to be current.
    $out = & kubectl --context $script:KubeContext @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($args -join ' ') failed: $($out -join [Environment]::NewLine)" }
    $out
}

function Test-ClusterReachable {
    & kubectl --context $script:KubeContext get --raw /readyz 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

function Assert-ClusterReachable {
    if (-not (Test-ClusterReachable)) {
        throw "Cluster '$script:ClusterName' is not reachable (context $script:KubeContext). Run bootstrap/new-cluster.ps1 (or 'k3d cluster start $script:ClusterName') first."
    }
}

function Assert-DockerRunning {
    & docker info --format '{{.ServerVersion}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker Desktop and run this script again.' }
}

$script:FieldManager = 'procure-bootstrap'
$script:LastAppliedAnnotation = 'kubectl.kubernetes.io/last-applied-configuration'

function Invoke-ServerSideApply {
    # Server-side apply: no last-applied-configuration annotation, which client-side apply fills with a copy of the object (for a
    # Secret: its data). Input is a file path or JSON on stdin; returns kubectl's line, e.g. "secret/procure-redis serverside-applied".
    # A no-op apply leaves resourceVersion unchanged (the idempotency check compares it).
    param([string] $Json, [string] $Path, [Parameter(Mandatory)] [string] $Description)
    $applyArgs = @('--context', $script:KubeContext, 'apply', '--server-side', '--field-manager', $script:FieldManager)
    $out = if ($Path) { & kubectl @applyArgs -f $Path 2>&1 } else { $Json | & kubectl @applyArgs -f - 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        # kubectl's error names the object and the problem; it does not echo data values.
        throw "kubectl apply of $Description failed: $($out -join [Environment]::NewLine)"
    }
    $out
}

function Remove-LastAppliedAnnotation {
    # Objects first made by client-side apply (before server-side apply was used) still carry the annotation; drop it once.
    param([Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [string] $Name, [string] $Namespace)
    $nsArgs = if ($Namespace) { @('-n', $Namespace) } else { @() }
    $annotations = & kubectl --context $script:KubeContext @nsArgs get $Kind $Name -o jsonpath='{.metadata.annotations}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl get $Kind $Name failed: $annotations" }
    if ("$annotations" -like "*$script:LastAppliedAnnotation*") {
        $out = & kubectl --context $script:KubeContext @nsArgs annotate $Kind $Name "$script:LastAppliedAnnotation-" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "removing $script:LastAppliedAnnotation from $Kind $Name failed: $out" }
        "$($Kind.ToLowerInvariant())/$Name annotation $script:LastAppliedAnnotation removed"
    }
}

function Invoke-Apply {
    # Applies one object (a hashtable) server-side and returns one line, e.g. "secret/procure-redis serverside-applied".
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Object)
    $json = $Object | ConvertTo-Json -Depth 20 -Compress
    $namespace = if ($Object.metadata.Contains('namespace')) { $Object.metadata.namespace } else { $null }
    $lines = @(Invoke-ServerSideApply -Json $json -Description "$($Object.kind) $($Object.metadata.name)")
    $lines += @(Remove-LastAppliedAnnotation -Kind $Object.kind -Name $Object.metadata.name -Namespace $namespace)
    ($lines | ForEach-Object { "$_" }) -join '; '
}

function ConvertTo-Base64 {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function New-SecretObject {
    # $Data: ordered key -> string value. $FileData: ordered key -> path of a file whose bytes become the value. $EncodedData: key -> value
    # already in base64 (a live Secret's data, kept as is).
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Name,
        [System.Collections.IDictionary] $Data = [ordered]@{},
        [System.Collections.IDictionary] $FileData = [ordered]@{},
        [System.Collections.IDictionary] $EncodedData = [ordered]@{},
        [string] $Type = 'Opaque')
    $encoded = [ordered]@{}
    foreach ($key in $EncodedData.Keys) { $encoded[$key] = $EncodedData[$key] }
    foreach ($key in $Data.Keys) { $encoded[$key] = ConvertTo-Base64 $Data[$key] }
    foreach ($key in $FileData.Keys) { $encoded[$key] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($FileData[$key])) }
    [ordered]@{
        apiVersion = 'v1'
        kind       = 'Secret'
        metadata   = [ordered]@{ name = $Name; namespace = $Namespace; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
        type       = $Type
        data       = $encoded
    }
}

function New-NamespaceObject {
    param([Parameter(Mandatory)] [string] $Name)
    [ordered]@{ apiVersion = 'v1'; kind = 'Namespace'; metadata = [ordered]@{ name = $Name } }
}

function Get-K3dCluster {
    # The k3d cluster `procure` as k3d reports it, or $null when it does not exist.
    $json = & k3d cluster list -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "k3d cluster list failed (is k3d installed and Docker running?): $($json -join [Environment]::NewLine)" }
    ($json -join "`n") | ConvertFrom-Json | Where-Object name -eq $script:ClusterName
}

function Get-OpenSsl {
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $git = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (Test-Path $git) { return $git }
    throw 'openssl not found (install Git for Windows, which ships it, or put openssl on PATH).'
}

function ConvertTo-Bytes([string] $quantity) {
    # Kubernetes memory quantities as the API returns them (Ki, Mi, Gi or plain bytes).
    if ($quantity -match '^(\d+)(Ki|Mi|Gi)?$') {
        $factor = switch ($Matches[2]) { 'Ki' { 1KB } 'Mi' { 1MB } 'Gi' { 1GB } default { 1 } }
        return [int64] $Matches[1] * $factor
    }
    throw "Unexpected memory quantity '$quantity'."
}

function Get-NodeBudget {
    # What the node really has: docker's CPU cap of the server container, the kubelet's memory capacity and allocatable.
    $nanoCpus = & docker inspect -f '{{.HostConfig.NanoCpus}}' "k3d-$script:ClusterName-server-0" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker inspect k3d-$script:ClusterName-server-0 failed: $nanoCpus" }
    $node = (Invoke-Kubectl get nodes -o json | Out-String | ConvertFrom-Json).items[0]
    [pscustomobject]@{
        Cpus              = [double] $nanoCpus / 1e9
        MemoryCapacity    = ConvertTo-Bytes $node.status.capacity.memory
        MemoryAllocatable = ConvertTo-Bytes $node.status.allocatable.memory
    }
}

function Get-ClusterPortExposure {
    # Every way the cluster's published ports could be reachable from outside the PC. Returns problem lines; none = loopback only.
    #  1. Docker's port bindings of every container of the cluster (load balancer, server): each HostIp must be 127.0.0.1 or ::1, and
    #     80, 443 and the API port must be published.
    #  2. Windows' listeners on those ports (Docker Desktop's backend opens them): each local address must be 127.0.0.1 or ::1.
    $loopback = @('127.0.0.1', '::1')
    $problems = [System.Collections.Generic.List[string]]::new()
    $ids = @(& docker ps -q --filter "label=k3d.cluster=$script:ClusterName" 2>&1)
    if ($LASTEXITCODE -ne 0) { $problems.Add("docker ps failed: $($ids -join ' ')"); return $problems }
    $published = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $ids | Where-Object { $_ }) {
        $raw = & docker inspect -f '{{.Name}}|{{json .HostConfig.PortBindings}}' $id 2>&1
        if ($LASTEXITCODE -ne 0) { $problems.Add("docker inspect $id failed: $raw"); continue }
        $name, $json = "$raw" -split '\|', 2
        $bindings = $json | ConvertFrom-Json -AsHashtable
        if (-not $bindings) { continue }
        foreach ($containerPort in $bindings.Keys) {
            foreach ($binding in @($bindings[$containerPort])) {
                $hostIp = "$($binding.HostIp)"
                if ($hostIp -notin $loopback) {
                    $shown = if ($hostIp) { $hostIp } else { '"" (all interfaces)' }
                    $problems.Add("container $($name.TrimStart('/')) publishes $containerPort on host $($shown):$($binding.HostPort), not on loopback")
                }
                if ("$($binding.HostPort)" -match '^\d+$') { [void] $published.Add([int] $binding.HostPort) }
            }
        }
    }
    foreach ($port in $script:PublishedPorts) {
        if (-not $published.Contains($port)) { $problems.Add("no container of cluster '$script:ClusterName' publishes host port $port") }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        if (-not $listeners) { $problems.Add("nothing listens on port $port on the PC"); continue }
        foreach ($listener in $listeners | Where-Object { $_.LocalAddress -notin $loopback }) {
            $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            $problems.Add("port $port listens on $($listener.LocalAddress) ($($process.ProcessName), PID $($listener.OwningProcess)), not only on loopback")
        }
    }
    $problems
}

function Get-ExpectedKeptBack {
    # Capacity minus allocatable the kubelet arguments of new-cluster.ps1 produce.
    (ConvertTo-Bytes $script:KubeReservedMemory) + (ConvertTo-Bytes $script:SystemReservedMemory) + (ConvertTo-Bytes $script:EvictionHardMemory)
}

function Set-CurrentUserOnlyAcl([string] $Dir) {
    # Creates $Dir if needed. Every run: only the current user (nobody inheriting from the profile) may read the keys in it. The folder
    # gets one protected rule, the files inherit it (/reset drops anything set on a file itself). /grant:r replaces, so a correct ACL
    # stays as it is; the files' contents are not touched.
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $icacls = & icacls $Dir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls could not restrict $Dir to $($env:USERNAME): $($icacls -join ' ')" }
    foreach ($file in Get-ChildItem -LiteralPath $Dir -File) {
        $icacls = & icacls $file.FullName /reset 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed on $($file.FullName): $($icacls -join ' ')" }
    }
    foreach ($item in @(Get-Item -LiteralPath $Dir) + @(Get-ChildItem -LiteralPath $Dir -File)) {
        $acl = Get-Acl -LiteralPath $item.FullName
        $rules = @($acl.Access)
        $others = @($rules | Where-Object { $_.IdentityReference.Value -notlike "*\$($env:USERNAME)" })
        if ($rules.Count -eq 0 -or $others) {
            throw "ACL of $($item.FullName) is not 'current user only' (other identities: $(($others | ForEach-Object IdentityReference) -join ', '))"
        }
    }
    if (-not (Get-Acl -LiteralPath $Dir).AreAccessRulesProtected) { throw "$Dir still inherits permissions from the profile." }
}

function Get-Gh {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path $default) { return $default }
    throw 'gh (GitHub CLI) not found.'
}

# The AppHost user secrets (the one source of every secret, plan 07 Global Constraints) as a hashtable key -> value. Never print it.
function Read-UserSecrets {
    $raw = & dotnet user-secrets list --json --id $AppHostUserSecretsId 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet user-secrets list --id $AppHostUserSecretsId failed." }
    $text = ($raw | ForEach-Object { "$_" }) -join "`n"
    $begin = $text.IndexOf('//BEGIN'); $end = $text.IndexOf('//END')
    if ($begin -lt 0 -or $end -lt $begin) { throw 'Unexpected output from dotnet user-secrets list --json.' }
    $text.Substring($begin + 7, $end - $begin - 7) | ConvertFrom-Json -AsHashtable
}
