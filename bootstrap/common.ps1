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
# Outside every repo; listed by name in DEMO PASSWORDS.txt.
$script:LocalCaDir = Join-Path $env:USERPROFILE '.procure-ai\local-ca'
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
    # $Data: ordered key -> string value. $FileData: ordered key -> path of a file whose bytes become the value.
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Name,
        [System.Collections.IDictionary] $Data = [ordered]@{},
        [System.Collections.IDictionary] $FileData = [ordered]@{},
        [string] $Type = 'Opaque')
    $encoded = [ordered]@{}
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
