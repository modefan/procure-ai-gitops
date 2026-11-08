#Requires -Version 7.4
<#
.SYNOPSIS
    Renders the argo-cd chart for hosted and local and checks the network policies (review 12c M5): on hosted argocd-server accepts no
    ingress over the pod network, and the other policies are exactly the chart's own.
.DESCRIPTION
    envs/hosted/argocd.yaml switches the chart's policies off (its argocd-server policy allows every source and cannot be changed) and
    declares the set itself in extraObjects. This test guards that set against drift, e.g. after argocd.chartVersion changes:
      1. hosted renders exactly argocd-server, argocd-repo-server, argocd-redis and argocd-application-controller, once each;
      2. hosted argocd-server: policyTypes [Ingress] and no ingress rule, and its podSelector selects the argocd-server pods;
      3. the other three are equal to the chart's own policies (the local render, which keeps them) and select their workload's pods;
      4. local keeps the chart's policies (argocd-server reachable for Traefik).
    Needs helm and Python with PyYAML (YAML to JSON); the chart comes from helm's repository cache or `helm pull`.
#>
[CmdletBinding()]
param(
    # A local argo-cd chart (.tgz or folder); default: the version in apps/values.yaml from helm's cache, pulled when missing.
    [string] $Chart = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()
function Pass([string] $message) { Write-Host "  PASS  $message" -ForegroundColor Green }
function Fail([string] $message) { Write-Host "  FAIL  $message" -ForegroundColor Red; $failures.Add($message) }

if (-not $Chart) {
    $version = [regex]::Match((Get-Content -Raw (Join-Path $root 'apps/values.yaml')), '(?m)^\s*chartVersion:\s*"?([0-9][^"\s]*)').Groups[1].Value
    if (-not $version) { throw 'No argocd chartVersion in apps/values.yaml.' }
    $cache = (& helm env HELM_REPOSITORY_CACHE).Trim()
    $Chart = Join-Path $cache "argo-cd-$version.tgz"
    if (-not (Test-Path $Chart)) {
        $pullDir = Join-Path ([IO.Path]::GetTempPath()) "argo-cd-$version-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        & helm pull oci://ghcr.io/argoproj/argo-helm/argo-cd --version $version -d $pullDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "helm pull argo-cd $version failed." }
        $Chart = Join-Path $pullDir "argo-cd-$version.tgz"
    }
}
Write-Host "Chart: $Chart"

function Get-Rendered([string] $environment, [string[]] $sets) {
    $setArgs = @($sets | ForEach-Object { '--set', $_ })
    $yaml = & helm template argocd $Chart -n argocd -f (Join-Path $root 'argocd/values.yaml') -f (Join-Path $root "envs/$environment/argocd.yaml") @setArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "helm template ($environment) failed: $($yaml -join ' ')" }
    $json = ($yaml -join "`n") | & python -c 'import sys, yaml, json; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d], sort_keys=True))'
    if ($LASTEXITCODE -ne 0) { throw 'YAML to JSON (python, PyYAML) failed.' }
    @(($json -join "`n") | ConvertFrom-Json -Depth 100)
}
function Get-Policies($docs) { @($docs | Where-Object kind -eq 'NetworkPolicy') }
# Keys are sorted by the YAML to JSON step, so equal specs give equal text.
function ConvertTo-Canonical($value) { ConvertTo-Json -InputObject $value -Depth 100 -Compress }
function Test-Selects($selector, $docs) {
    # True when some rendered workload's pod template carries every label of the selector.
    foreach ($doc in $docs | Where-Object kind -in 'Deployment', 'StatefulSet') {
        $labels = $doc.spec.template.metadata.labels
        $all = $true
        foreach ($p in $selector.matchLabels.PSObject.Properties) { if ($labels.($p.Name) -ne $p.Value) { $all = $false } }
        if ($all) { return $true }
    }
    $false
}

# The two environments as the argocd Application renders them (the apps chart passes the switches as valuesObject).
$hosted = Get-Rendered hosted @('configs.cm.admin\.enabled=true', 'server.ingress.enabled=false')
$local = Get-Rendered local @('configs.cm.admin\.enabled=true', 'server.ingress.enabled=true')
$hostedPolicies = Get-Policies $hosted
$localPolicies = Get-Policies $local

$expected = @('argocd-application-controller', 'argocd-redis', 'argocd-repo-server', 'argocd-server')
$names = @($hostedPolicies | ForEach-Object { $_.metadata.name } | Sort-Object)
if (($names -join ',') -eq ($expected -join ',')) { Pass "1. hosted renders exactly $($expected -join ', ')" }
else { Fail "1. hosted renders policies [$($names -join ', ')], expected [$($expected -join ', ')]" }

$server = @($hostedPolicies | Where-Object { $_.metadata.name -eq 'argocd-server' })
if ($server.Count -eq 1) {
    $spec = $server[0].spec
    $noIngress = (@($spec.policyTypes) -join ',') -eq 'Ingress' -and @($spec.ingress | Where-Object { $_ -ne $null }).Count -eq 0
    if ($noIngress) { Pass '2. hosted argocd-server: policyTypes [Ingress], no ingress rule' } else { Fail "2. hosted argocd-server allows ingress: $(ConvertTo-Canonical $spec)" }
    if (Test-Selects $spec.podSelector $hosted) { Pass '2. hosted argocd-server policy selects the argocd-server pods' } else { Fail '2. hosted argocd-server policy selects no rendered pod' }
}

foreach ($name in $expected | Where-Object { $_ -ne 'argocd-server' }) {
    $mine = @($hostedPolicies | Where-Object { $_.metadata.name -eq $name })
    $chartOwn = @($localPolicies | Where-Object { $_.metadata.name -eq $name })
    if ($mine.Count -ne 1 -or $chartOwn.Count -ne 1) { Fail "3. $name missing (hosted $($mine.Count), chart $($chartOwn.Count))"; continue }
    if ((ConvertTo-Canonical $mine[0].spec) -eq (ConvertTo-Canonical $chartOwn[0].spec)) { Pass "3. hosted $name equals the chart's policy" }
    else { Fail "3. hosted $name differs from the chart's: $(ConvertTo-Canonical $mine[0].spec) vs $(ConvertTo-Canonical $chartOwn[0].spec)" }
    if (Test-Selects $mine[0].spec.podSelector $hosted) { Pass "3. hosted $name selects its pods" } else { Fail "3. hosted $name selects no rendered pod" }
}

$localServer = @($localPolicies | Where-Object { $_.metadata.name -eq 'argocd-server' })
if ($localServer.Count -eq 1 -and (ConvertTo-Canonical @($localServer[0].spec.ingress)) -eq '[{}]') { Pass "4. local keeps the chart's argocd-server policy (ingress from everywhere, for Traefik)" }
else { Fail "4. local argocd-server policy is not the chart's: $(ConvertTo-Canonical $localServer)" }

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) FAIL" -ForegroundColor Red; exit 1 }
Write-Host 'All passed.' -ForegroundColor Green
