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
# The user-secrets store the bootstrap reads (Select-ProcureCluster switches it): the AppHost's for the local cluster, a separate one for
# the hosted cluster (plan 08 ruling 11), so the public demo shares no secret with Dale's PC.
$script:UserSecretsId = $script:AppHostUserSecretsId

# --- The hosted VM (plan 08 Task 11, ruling 10): a Contabo Cloud VPS, Terraform in infra/hosted, k3s by cloud-init. -------------------
# Everything that must stay off the repos lives here (current user only; listed by name in DEMO PASSWORDS.txt): the SSH key pair
# procure-hosted_ed25519(.pub), known_hosts, the Terraform state terraform.tfstate, host.json (addresses, user) and the kubeconfig.
$script:HostedDir = Join-Path $env:USERPROFILE '.procure-ai\hosted'
$script:HostedSshKey = Join-Path $script:HostedDir 'procure-hosted_ed25519'
$script:HostedKnownHosts = Join-Path $script:HostedDir 'known_hosts'
$script:HostedKubeconfig = Join-Path $script:HostedDir 'kubeconfig'
$script:HostedHostFile = Join-Path $script:HostedDir 'host.json'
$script:HostedTunnelPidFile = Join-Path $script:HostedDir 'tunnel.pid'
$script:HostedStateFile = Join-Path $script:HostedDir 'terraform.tfstate'
$script:HostedKubeContext = 'procure-hosted'
$script:HostedUserSecretsId = 'procure-ai-hosted'
# The Kubernetes API listens only on the VM's node address (a dummy interface; infra/hosted, k3s bind-address); open-tunnel.ps1 forwards this loopback
# port of Dale's PC to it over SSH. Not 6550 (the local cluster's API port), so both clusters can be used side by side.
$script:HostedTunnelPort = 16443
# Pinned k3s release of the hosted VM: the local cluster's minor (K3sImage above), the newest patch when the VM was created (a public
# node gets the security fixes). Changing it needs an upgrade on the VM (or a new VM), not only this line.
$script:HostedK3sVersion = 'v1.35.10+k3s1'
# What Dale bought and approved (plan 08, DALE DECISION 2026-11-07 ~16:30): Contabo Cloud VPS 8 (product V155, region EU, 8 vCPU, 24 GB,
# 300 GB), instance 203735351, EUR 14.00 a month, monthly term. Terraform adopts exactly this instance and never orders or cancels one
# (infra/hosted/variables.tf validates the ID; new-hosted-cluster.ps1 refuses any other plan).
$script:HostedInstanceId = '203735351'
$script:HostedProductId = 'V155'
$script:HostedMonthlyPrice = 'EUR 14.00'
# The Contabo password secret that keeps Dale's root password (console login) valid across the reinstall; created once from DEMO
# PASSWORDS.txt ("=== Contabo ===", "VPS root password") by new-hosted-cluster.ps1, value never printed.
$script:HostedRootPasswordSecretName = 'procure-hosted-root-password'
# The Cloudflare DNS records Terraform keeps (one A record each, DNS only; no AAAA, k3s is IPv4 only): <host>.<domain> -> the server.
$script:HostedDomain = 'daleabels.com'
# The operator's own hosts (plan 08b Task 4): pgAdmin, the MongoDB UI, Redis Insight, RabbitMQ's management UI, the break-glass dashboard. Keep
# infra/hosted/variables.tf dns_hosts equal; every name is on the one public certificate (install-cert-manager.ps1).
$script:HostedDnsHosts = @('procure', 'auth', 'dashboard', 'pgadmin', 'mongo', 'redis', 'rabbitmq', 'dashboard-direct')
$script:HostedCloudflareZoneId = '93c854c6f17e0cbb8f2b7e9395f7828c'
# The hosted ghcr-pull Secret holds a classic read-only PAT (read:packages, user modefan; DEMO PASSWORDS.txt "GitHub Container Registry
# (GHCR)", user env var GHCR_READ_TOKEN). It expires on this date: while the packages are private an expired token makes the next hosted
# deploy fail with ImagePullBackOff (running pods keep their cached images). Test-HostBaseline.ps1 warns 21 days before and fails after.
# Renew: a new token with the same scope (CLAUDE.md learning 2026-11-07), DEMO PASSWORDS.txt and the env var, new-secrets.ps1 -Environment
# hosted, then this date. Not needed once the packages are public (plan 08 Task 17).
$script:GhcrPullTokenExpires = [datetime] '2027-02-05'

# kubectl and helm arguments that select the cluster; every kubectl/helm call of the bootstrap uses them (never the current context).
$script:KubectlArgs = @('--context', $script:KubeContext)
$script:HelmArgs = @('--kube-context', $script:KubeContext)

function Select-ProcureCluster {
    # Points the bootstrap at the cluster of an environment: 'hosted' is the VM (its own kubeconfig through the SSH tunnel, opened when it
    # is not up yet; the hosted user-secrets store), anything else the local k3d cluster. Changes nothing outside this PowerShell session's
    # script scope: no KUBECONFIG variable, no current context.
    param([Parameter(Mandatory)] [string] $Environment)
    if ($Environment -ne 'hosted') { return }
    $script:ClusterName = 'procure-hosted'
    $script:KubeContext = $script:HostedKubeContext
    $script:KubectlArgs = @('--kubeconfig', $script:HostedKubeconfig, '--context', $script:KubeContext)
    $script:HelmArgs = @('--kubeconfig', $script:HostedKubeconfig, '--kube-context', $script:KubeContext)
    $script:UserSecretsId = $script:HostedUserSecretsId
    if (-not (Test-Path $script:HostedKubeconfig)) { throw "No hosted kubeconfig at $script:HostedKubeconfig. Run bootstrap/hosted/new-hosted-cluster.ps1 first." }
    if (-not (Test-ClusterReachable)) { & (Join-Path $PSScriptRoot 'hosted/open-tunnel.ps1') | Out-Host }
}

function Get-HostedHost {
    # host.json, written by new-hosted-cluster.ps1 from the Terraform outputs: instanceId, ipv4, ipv6, nodeIp, user, firewallId, dnsNames.
    if (-not (Test-Path $script:HostedHostFile)) { throw "No $script:HostedHostFile. Run bootstrap/hosted/new-hosted-cluster.ps1 first." }
    Get-Content -Raw $script:HostedHostFile | ConvertFrom-Json
}

function Get-ApiToken([string] $name) {
    # A token from the process environment or, for a shell started before it was set, the user env vars. Never printed.
    $value = [Environment]::GetEnvironmentVariable($name) ?? [Environment]::GetEnvironmentVariable($name, 'User')
    if ([string]::IsNullOrWhiteSpace($value)) { throw "The user env var $name is not set (DEMO PASSWORDS.txt names the token)." }
    $value
}

$script:ContaboToken = $null
$script:ContaboTokenExpires = [datetime]::MinValue
function Get-ContaboToken {
    # OAuth2 password grant with Dale's API credentials (user env vars CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET, CONTABO_USER,
    # CONTABO_PASSWORD), cached until shortly before it expires. auth.contabo.com sits behind a bot check that challenges PowerShell's
    # default user agent, so the request names itself like a command-line client.
    if ($script:ContaboToken -and (Get-Date) -lt $script:ContaboTokenExpires) { return $script:ContaboToken }
    $body = @{
        grant_type = 'password'; client_id = (Get-ApiToken 'CONTABO_CLIENT_ID'); client_secret = (Get-ApiToken 'CONTABO_CLIENT_SECRET')
        username = (Get-ApiToken 'CONTABO_USER'); password = (Get-ApiToken 'CONTABO_PASSWORD')
    }
    $response = Invoke-RestMethod -Method Post -Uri 'https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token' -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -UserAgent 'procure-bootstrap/1.0 (curl-compatible)'
    $script:ContaboToken = $response.access_token
    $script:ContaboTokenExpires = (Get-Date).AddSeconds([int] $response.expires_in - 30)
    $script:ContaboToken
}

function Invoke-ContaboApi {
    # A call to the Contabo API (https://api.contabo.com/v1/<path>); every request carries its own x-request-id. Returns the parsed body.
    param([Parameter(Mandatory)] [string] $Path, [string] $Method = 'Get', $Body)
    $headers = @{ Authorization = "Bearer $(Get-ContaboToken)"; 'x-request-id' = [guid]::NewGuid().ToString() }
    $args2 = @{ Method = $Method; Uri = "https://api.contabo.com/v1/$Path"; Headers = $headers }
    if ($null -ne $Body) { $args2.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $args2.ContentType = 'application/json' }
    Invoke-RestMethod @args2
}

function Invoke-CloudflareApi([string] $path) {
    # GET on the Cloudflare API with the DNS token (CLOUDFLARE_API_TOKEN: DNS Write + Zone Read on daleabels.com only).
    Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-ApiToken 'CLOUDFLARE_API_TOKEN')" } "https://api.cloudflare.com/client/v4/$path"
}

function Get-HostedDnsRecords {
    # The zone's A/AAAA records for the hosted host names (type, name, content, proxied).
    # Asked by exact name, one host at a time, so the answer never depends on how many other records the zone holds.
    @(foreach ($h in $script:HostedDnsHosts) {
        $name = "$h.$script:HostedDomain"
        (Invoke-CloudflareApi "zones/$script:HostedCloudflareZoneId/dns_records?name=$([uri]::EscapeDataString($name))&per_page=100").result |
            Where-Object { $_.name -eq $name -and $_.type -in 'A', 'AAAA' }
    })
}

function Get-HostedSshArgs {
    # ssh options for the VM: its own key and known_hosts only (nothing from ~/.ssh), no prompts, no agent.
    @('-i', $script:HostedSshKey, '-o', "UserKnownHostsFile=$script:HostedKnownHosts", '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
        '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15')
}

function Get-HostedTunnelProcess {
    # The SSH tunnel of open-tunnel.ps1: the ssh process whose PID is in tunnel.pid, if it is still running (else $null). Scripts that open
    # the tunnel only when needed decide by this whether they own it (review 12c M3): a live process means another script's tunnel, which
    # they reuse and never close, even when the API answers slowly or not at all for a moment.
    if (-not (Test-Path $script:HostedTunnelPidFile)) { return $null }
    $text = (Get-Content -Raw $script:HostedTunnelPidFile).Trim()
    if ($text -notmatch '^\d+$') { return $null }
    $process = Get-Process -Id ([int] $text) -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq 'ssh') { return $process }
    $null
}

function Invoke-HostedSsh {
    # Runs a command on the VM as the admin user and returns its output lines; throws on a non-zero exit unless -AllowFailure (then
    # $LASTEXITCODE tells). Only for commands whose output holds no secret (the kubeconfig is fetched by new-hosted-cluster.ps1 itself).
    param([Parameter(Mandatory)] [string] $Command, [switch] $AllowFailure)
    # The VM's bash reads a carriage return (CR) as part of the command: a here-string from a CRLF checkout (core.autocrlf) would end every line with one
    # (plan 08 Task 12 push report: Test-HostBaseline's AppArmor probe broke that way). .gitattributes pins *.ps1 to LF as well.
    $Command = $Command -replace "`r", ''
    $hostInfo = Get-HostedHost
    $out = & ssh @(Get-HostedSshArgs) "$($hostInfo.user)@$($hostInfo.ipv4)" $Command 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "ssh '$Command' failed ($LASTEXITCODE): $($out -join [Environment]::NewLine)" }
    $out | ForEach-Object { "$_" }
}

function Invoke-Kubectl {
    # kubectl against the procure cluster only, never whatever context happens to be current.
    $out = & kubectl @KubectlArgs @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($args -join ' ') failed: $($out -join [Environment]::NewLine)" }
    $out
}

function Test-ClusterReachable {
    & kubectl @KubectlArgs get --raw /readyz 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

function Assert-ClusterReachable {
    if (-not (Test-ClusterReachable)) {
        if ($script:KubeContext -eq $script:HostedKubeContext) {
            throw "The hosted cluster is not reachable through the tunnel (127.0.0.1:$script:HostedTunnelPort). Run bootstrap/hosted/open-tunnel.ps1 and check the VM."
        }
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
    $applyArgs = @($script:KubectlArgs) + @('apply', '--server-side', '--field-manager', $script:FieldManager)
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
    $annotations = & kubectl @KubectlArgs @nsArgs get $Kind $Name -o jsonpath='{.metadata.annotations}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl get $Kind $Name failed: $annotations" }
    if ("$annotations" -like "*$script:LastAppliedAnnotation*") {
        $out = & kubectl @KubectlArgs @nsArgs annotate $Kind $Name "$script:LastAppliedAnnotation-" 2>&1
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

# The user secrets of the selected cluster ($UserSecretsId: the AppHost's for local, procure-ai-hosted for hosted; the one source of
# every secret, plan 07 Global Constraints) as a hashtable key -> value. Never print it.
function Read-UserSecrets {
    # A store that was never written has no file yet: empty (the hosted store before the first new-secrets.ps1 -Environment hosted).
    $store = Join-Path $env:APPDATA "Microsoft\UserSecrets\$script:UserSecretsId\secrets.json"
    if (-not (Test-Path $store)) { return @{} }
    $raw = & dotnet user-secrets list --json --id $script:UserSecretsId 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet user-secrets list --id $script:UserSecretsId failed." }
    $text = ($raw | ForEach-Object { "$_" }) -join "`n"
    $begin = $text.IndexOf('//BEGIN'); $end = $text.IndexOf('//END')
    if ($begin -lt 0 -or $end -lt $begin) { throw 'Unexpected output from dotnet user-secrets list --json.' }
    $text.Substring($begin + 7, $end - $begin - 7) | ConvertFrom-Json -AsHashtable
}

# DEMO PASSWORDS.txt (CLAUDE.md "Secrets": every credential's value is kept there; local Desktop, outside every repo).
$script:DemoPasswordsFile = Join-Path $env:USERPROFILE 'Desktop\DEMO PASSWORDS.txt'

function Set-DemoPasswordEntry {
    # Puts "<Label>: <Value>" into the section "=== <Section>..." of DEMO PASSWORDS.txt: replaces the line that starts with -Key (a
    # stable prefix of the label), or adds it at the end of the section (the section at the end of the file when there is none). Prints
    # and returns nothing about the value; the file keeps its CRLF line ends and has no BOM. Review 12c N6: scripts that make a credential
    # store it themselves instead of asking for a copy.
    param(
        [Parameter(Mandatory)] [string] $Section,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Value,
        [string] $Path = $script:DemoPasswordsFile
    )
    if (-not $Label.StartsWith($Key)) { throw "The label must start with the key '$Key'." }
    if ($Value -match '[\r\n]') { throw 'The value must be one line.' }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) { foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) } }
    $header = "=== $Section"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith($header)) { $start = $i; break } }
    $entry = "$($Label): $Value"
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add("$header ===")
        $lines.Add($entry)
    } else {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('===')) { $end = $i; break } }
        $found = -1
        # TrimStart: the file's readers allow indented entries (e.g. hosted/new-hosted-cluster.ps1, '^\s*VPS root password'); re-review R2.
        for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i].TrimStart().StartsWith($Key)) { $found = $i; break } }
        if ($found -ge 0) { $lines[$found] = $entry }
        else {
            # After the section's last non-empty line.
            $at = $end
            while ($at - 1 -gt $start -and $lines[$at - 1] -eq '') { $at-- }
            $lines.Insert($at, $entry)
        }
    }
    Write-DemoPasswordsFile -Lines $lines -Path $Path
}

function Write-DemoPasswordsFile {
    # Writes DEMO PASSWORDS.txt (CRLF, no BOM). Never truncates the only store of every credential in place (re-review R2): writes a
    # temporary file next to it, then swaps it in. File.Replace keeps the previous version as '<file>.bak' while it swaps; after a
    # successful swap the .bak is deleted, so no second plaintext copy of every credential stays on the Desktop (plan 08 fix wave ruling
    # R3). Only a failed swap leaves it, for recovery.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [System.Collections.Generic.List[string]] $Lines, [Parameter(Mandatory)] [string] $Path)
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $backup = "$Path.bak"
    try {
        [IO.File]::WriteAllText($temporary, (($Lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
        if (Test-Path $Path) { [IO.File]::Replace($temporary, $Path, $backup) } else { [IO.File]::Move($temporary, $Path) }
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $backup) { throw "Could not delete $backup (a plaintext copy of the old file); delete it by hand." }
    } finally {
        Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue
    }
}

function Sync-DemoPasswordSection {
    # Puts every "<label>: <value>" of -Entries (ordered label -> value) into the section "=== <Section>..." of DEMO PASSWORDS.txt: a line
    # whose text (indent ignored) starts with exactly "<label>: " is replaced, a missing one is added at the end of the section (the section
    # at the end of the file when there is none). Writes the file once, and only when something changed. Returns the number of entries
    # added or changed; prints nothing about the values. Used by new-secrets.ps1 to keep the copy of a user-secrets store current (Dale's
    # rule 2026-11-07: every generated secret has its value in DEMO PASSWORDS.txt; plan 08 final review B M4).
    param(
        [Parameter(Mandatory)] [string] $Section,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Entries,
        [string] $Path = $script:DemoPasswordsFile
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) { foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) } }
    $header = "=== $Section"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith($header)) { $start = $i; break } }
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add("$header ===")
        $start = $lines.Count - 1
    }
    $changed = 0
    foreach ($label in $Entries.Keys) {
        $value = "$($Entries[$label])"
        if ($value -match '[\r\n]') { throw "The value of '$label' must be one line." }
        $entry = "$($label): $value"
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('===')) { $end = $i; break } }
        $found = -1
        for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i].TrimStart().StartsWith("$($label): ", [StringComparison]::Ordinal)) { $found = $i; break } }
        if ($found -ge 0) {
            if ($lines[$found].TrimStart() -ceq $entry) { continue }
            $lines[$found] = $entry
        } else {
            $at = $end
            while ($at - 1 -gt $start -and $lines[$at - 1] -eq '') { $at-- }
            $lines.Insert($at, $entry)
        }
        $changed++
    }
    if ($changed -gt 0) { Write-DemoPasswordsFile -Lines $lines -Path $Path }
    $changed
}

# --- The operator's logins (plan 08b Task 4): read back from DEMO PASSWORDS.txt, and the one-time codes computed from it. ---
function Read-DemoPasswordSection([string] $section, [string] $prefix, [string] $Path = $script:DemoPasswordsFile) {
    # name -> value of every "<prefix><name>: <value>" line of the section "=== <section>..." of DEMO PASSWORDS.txt (indent ignored).
    # Values are returned, never printed.
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Path not found." }
    $entries = @{}
    $inside = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith('===')) { $inside = $line.StartsWith("=== $section"); continue }
        if (-not $inside) { continue }
        $text = $line.TrimStart()
        if (-not $text.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        $colon = $text.IndexOf(': ', $prefix.Length)
        if ($colon -lt 0) { continue }
        $entries[$text.Substring($prefix.Length, $colon - $prefix.Length)] = $text.Substring($colon + 2)
    }
    if ($entries.Count -eq 0) { throw "No entries in the section '=== $section' of $Path (bootstrap/new-secrets.ps1 writes it)." }
    $entries
}

function Get-ServerClockOffset([string] $Url, [string] $ResolveTo) {
    # Seconds to add to this PC's clock to get the time of the server behind $Url (its HTTP Date header, one HEAD request; whole seconds).
    # A one-time code is only valid for 30 seconds and this PC's clock was 35 s fast on 2026-11-08 (Windows time sync off or slow), so the
    # codes are computed with the server's time. $null when the server cannot be asked.
    $curl = @("$env:SystemRoot\System32\curl.exe", 'C:\Program Files\Git\mingw64\bin\curl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    $resolve = if ($ResolveTo) { @('--resolve', "$(([Uri] $Url).Host):443:$ResolveTo") } else { @() }
    $before = [DateTimeOffset]::UtcNow
    $headers = & $curl -sS -k --ssl-no-revoke --max-time 10 -I @resolve $Url 2>$null
    $after = [DateTimeOffset]::UtcNow
    $date = $headers | Where-Object { $_ -match '^date:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1
    $server = [DateTimeOffset]::MinValue
    if (-not $date -or -not [DateTimeOffset]::TryParse($date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $server)) { return $null }
    $local = $before.AddTicks(($after - $before).Ticks / 2)
    [int] [Math]::Round(($server - $local).TotalSeconds)
}

function Get-TotpCode([string] $base32, [int] $OffsetSeconds = 0) {
    # RFC 6238 with the authenticator defaults (HMAC-SHA1, 6 digits, 30-second steps) over the RFC 4648 Base32 key. -OffsetSeconds: the
    # server's clock minus this PC's (Get-ServerClockOffset).
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = $base32.ToUpperInvariant().TrimEnd('=').Replace(' ', '')
    $bits = -join ($clean.ToCharArray() | ForEach-Object {
        $index = $alphabet.IndexOf($_)
        if ($index -lt 0) { throw 'The TOTP secret is not Base32.' }
        [Convert]::ToString($index, 2).PadLeft(5, '0')
    })
    $key = [byte[]] @(for ($i = 0; $i + 8 -le $bits.Length; $i += 8) { [Convert]::ToByte($bits.Substring($i, 8), 2) })
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $OffsetSeconds
    $counter = [BitConverter]::GetBytes([long][Math]::Floor($now / 30))
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counter) }
    $hash = [Security.Cryptography.HMACSHA1]::new($key).ComputeHash($counter)
    $offset = $hash[$hash.Length - 1] -band 0x0f
    # Every term in its own parentheses: PowerShell's -band, -bor and -shl share one precedence and run left to right.
    $binary = ((([int] $hash[$offset]) -band 0x7f) -shl 24) -bor (([int] $hash[$offset + 1]) -shl 16) -bor (([int] $hash[$offset + 2]) -shl 8) -bor ([int] $hash[$offset + 3])
    [pscustomobject]@{ Code = ($binary % 1000000).ToString('000000'); SecondsLeft = 30 - ($now % 30) }
}

function Read-OperatorSecrets([ValidateSet('hosted', 'local')] [string] $Environment, [string] $Path = $script:DemoPasswordsFile) {
    # The section bootstrap/new-secrets.ps1 keeps for the environment (plan 08b Task 4): hosted "<name>: <value>", local "Parameters:<name>: <value>".
    if ($Environment -eq 'hosted') { Read-DemoPasswordSection 'procure-ai hosted (Contabo) secrets' '' $Path }
    else { Read-DemoPasswordSection 'procure-ai local: all AppHost user secrets' 'Parameters:' $Path }
}

# kcadm inside the Keycloak pod (add-argocd-admin.ps1, tests/Test-AddArgocdAdmin.ps1, tests/Test-Smoke.ps1) signs in to the master realm as
# the automation client procure-automation (plan 08b Task 4 fix round 1: the bootstrap admin is disabled once that client works) when Secret
# procure-keycloak holds automation-client-secret, else as the bootstrap admin from the pod's own environment. The client's secret goes to
# the pod as the FIRST line of kubectl exec's stdin (Get-KeycloakKcadmSecretLine), never on a command line; $KeycloakKcadmSignIn is the bash
# that reads that line and defines kc_sign_in <config file>.
$script:KeycloakKcadmSignIn = @'
IFS= read -r KC_AUTOMATION_SECRET || true
KC_AUTOMATION_SECRET=${KC_AUTOMATION_SECRET%$'\r'}
kc_sign_in() {
  if [ -n "$KC_AUTOMATION_SECRET" ]; then
    KC_CLI_CLIENT_SECRET="$KC_AUTOMATION_SECRET" /opt/keycloak/bin/kcadm.sh config credentials --config "$1" --server http://localhost:8080 \
      --realm master --client procure-automation </dev/null >/dev/null 2>&1
  else
    KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" /opt/keycloak/bin/kcadm.sh config credentials --config "$1" --server http://localhost:8080 \
      --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" </dev/null >/dev/null 2>&1
  fi
}
'@ -replace "`r", ''

function Get-KeycloakKcadmSecretLine {
    # The automation client's secret from Secret procure/procure-keycloak (key automation-client-secret), '' when the key does not exist (an
    # older cluster: kc_sign_in then uses the bootstrap admin). Never printed.
    $encoded = & kubectl @script:KubectlArgs -n procure get secret procure-keycloak -o 'jsonpath={.data.automation-client-secret}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$encoded")) { return '' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$encoded".Trim()))
}
