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

function Invoke-Apply {
    # Applies one object (a hashtable) and returns kubectl's result line, e.g. "secret/procure-redis unchanged".
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Object)
    $json = $Object | ConvertTo-Json -Depth 20 -Compress
    $out = $json | & kubectl --context $script:KubeContext apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        # kubectl's error names the object and the problem; it does not echo data values.
        throw "kubectl apply of $($Object.kind) $($Object.metadata.name) failed: $($out -join [Environment]::NewLine)"
    }
    $out
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

function Get-OpenSsl {
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $git = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (Test-Path $git) { return $git }
    throw 'openssl not found (install Git for Windows, which ships it, or put openssl on PATH).'
}
