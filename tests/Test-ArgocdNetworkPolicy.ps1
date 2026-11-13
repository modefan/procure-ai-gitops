#Requires -Version 7.4
<#
.SYNOPSIS
    Renders the argo-cd chart for hosted and local and checks the network policies (review 12c M5, plan 08c Task 1): on hosted argocd-server
    accepts ingress from Traefik's pods only (none at all with the ingress switch off), the gate only Traefik, and the other policies are
    exactly the chart's own.
.DESCRIPTION
    envs/hosted/argocd.yaml switches the chart's policies off (its argocd-server policy allows every source and cannot be changed) and
    declares the set itself in extraObjects. This test guards that set against drift, e.g. after argocd.chartVersion changes. Hosted is
    rendered with its own switches from envs/hosted/apps.yaml (ingress on since plan 08c) and once more with the ingress off:
      0. hosted has the ingress switch on;
      1. hosted renders exactly argocd-server, argocd-repo-server, argocd-redis, argocd-application-controller and (ingress on) argocd-gate,
         once each;
      2. hosted argocd-server: policyTypes [Ingress]; with the ingress on exactly one rule: from pods app.kubernetes.io/name=traefik in
         namespace kube-system (both selectors in ONE peer, so neither every pod of kube-system nor a traefik-named pod elsewhere), on port
         `server` (8080) only; with the ingress off no rule at all; its podSelector selects the argocd-server pods;
      2b. hosted argocd-gate (the Keycloak gate): ingress only from Traefik's pods on its http port; egress only DNS and Traefik's websecure
         port;
      3. the other three are equal to the chart's own policies (the local render, which keeps them) and select their workload's pods;
      4. local keeps the chart's policies (argocd-server reachable for Traefik) and has no gate.
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

function Get-Switch([string] $environment, [string] $name) {
    # argocd.<name> as the apps chart sees it: apps/values.yaml, overridden by envs/<env>/apps.yaml.
    $value = 'true'
    foreach ($file in (Join-Path $root 'apps/values.yaml'), (Join-Path $root "envs/$environment/apps.yaml")) {
        $block = [regex]::Match((Get-Content -Raw $file), '(?ms)^argocd:\s*\r?\n(.*?)(?=^\S|\z)').Groups[1].Value
        $m = [regex]::Match($block, "(?m)^\s+$($name):\s*(true|false)\s*(#.*)?$")
        if ($m.Success) { $value = $m.Groups[1].Value }
    }
    $value
}
function Test-TraefikPeer($peer) {
    # Traefik's pods as ONE peer: namespace kube-system AND label app.kubernetes.io/name=traefik, nothing else.
    $peer.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'kube-system' -and
        $peer.podSelector.matchLabels.'app.kubernetes.io/name' -eq 'traefik' -and
        @($peer.namespaceSelector.matchLabels.PSObject.Properties).Count -eq 1 -and @($peer.podSelector.matchLabels.PSObject.Properties).Count -eq 1 -and
        -not $peer.ipBlock
}

# The environments as the argocd Application renders them (the apps chart passes the switches as valuesObject); hosted also with the
# ingress off.
$hostedIngress = Get-Switch hosted 'ingressEnabled'
$hosted = Get-Rendered hosted @("configs.cm.admin\.enabled=$(Get-Switch hosted 'adminEnabled')", "server.ingress.enabled=$hostedIngress")
$hostedOff = Get-Rendered hosted @('configs.cm.admin\.enabled=true', 'server.ingress.enabled=false')
$local = Get-Rendered local @('configs.cm.admin\.enabled=true', 'server.ingress.enabled=true')
$hostedPolicies = Get-Policies $hosted
$localPolicies = Get-Policies $local
if ($hostedIngress -eq 'true') { Pass '0. hosted argocd.ingressEnabled is true (the public host, plan 08c Task 1)' }
else { Fail '0. hosted argocd.ingressEnabled is not true (plan 08c Task 1 puts Argo CD on its public host)' }

$expected = @('argocd-application-controller', 'argocd-redis', 'argocd-repo-server', 'argocd-server')
$expectedOn = @('argocd-application-controller', 'argocd-gate', 'argocd-redis', 'argocd-repo-server', 'argocd-server')
$names = @($hostedPolicies | ForEach-Object { $_.metadata.name } | Sort-Object)
if (($names -join ',') -eq ($expectedOn -join ',')) { Pass "1. hosted renders exactly $($expectedOn -join ', ')" }
else { Fail "1. hosted renders policies [$($names -join ', ')], expected [$($expectedOn -join ', ')]" }
$namesOff = @(Get-Policies $hostedOff | ForEach-Object { $_.metadata.name } | Sort-Object)
if (($namesOff -join ',') -eq ($expected -join ',')) { Pass "1. hosted with the ingress off renders exactly $($expected -join ', ') (no gate)" }
else { Fail "1. hosted with the ingress off renders policies [$($namesOff -join ', ')], expected [$($expected -join ', ')]" }

$server = @($hostedPolicies | Where-Object { $_.metadata.name -eq 'argocd-server' })
if ($server.Count -eq 1) {
    $spec = $server[0].spec
    $rules = @($spec.ingress | Where-Object { $_ -ne $null })
    $onlyTraefik = (@($spec.policyTypes) -join ',') -eq 'Ingress' -and $rules.Count -eq 1 -and @($rules[0].from).Count -eq 1 -and
        (Test-TraefikPeer $rules[0].from[0]) -and @($rules[0].ports).Count -eq 1 -and $rules[0].ports[0].port -eq 'server' -and $rules[0].ports[0].protocol -eq 'TCP'
    if ($onlyTraefik) { Pass "2. hosted argocd-server: policyTypes [Ingress], one rule: Traefik's pods (kube-system) on port server only" }
    else { Fail "2. hosted argocd-server allows more (or other) than Traefik on port server: $(ConvertTo-Canonical $spec)" }
    if (Test-Selects $spec.podSelector $hosted) { Pass '2. hosted argocd-server policy selects the argocd-server pods' } else { Fail '2. hosted argocd-server policy selects no rendered pod' }
}
$serverOff = @(Get-Policies $hostedOff | Where-Object { $_.metadata.name -eq 'argocd-server' })
if ($serverOff.Count -eq 1 -and (@($serverOff[0].spec.policyTypes) -join ',') -eq 'Ingress' -and @($serverOff[0].spec.ingress | Where-Object { $_ -ne $null }).Count -eq 0) {
    Pass '2. hosted argocd-server with the ingress off: no ingress rule at all'
} else { Fail "2. hosted argocd-server with the ingress off allows ingress: $(ConvertTo-Canonical $serverOff)" }

$gate = @($hostedPolicies | Where-Object { $_.metadata.name -eq 'argocd-gate' })
if ($gate.Count -eq 1) {
    $spec = $gate[0].spec
    $in = @($spec.ingress | Where-Object { $_ -ne $null })
    $out = @($spec.egress | Where-Object { $_ -ne $null })
    $inOk = $in.Count -eq 1 -and @($in[0].from).Count -eq 1 -and (Test-TraefikPeer $in[0].from[0]) -and @($in[0].ports).Count -eq 1 -and $in[0].ports[0].port -eq 'http'
    $dns = @($out | Where-Object { @($_.to).Count -eq 1 -and $_.to[0].podSelector.matchLabels.'k8s-app' -eq 'kube-dns' -and $_.to[0].namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'kube-system' })
    $toTraefik = @($out | Where-Object { @($_.to).Count -eq 1 -and (Test-TraefikPeer $_.to[0]) })
    $outOk = $out.Count -eq 2 -and $dns.Count -eq 1 -and ((@($dns[0].ports | ForEach-Object { "$($_.port)/$($_.protocol)" }) | Sort-Object) -join ',') -eq '53/TCP,53/UDP' -and
        $toTraefik.Count -eq 1 -and @($toTraefik[0].ports).Count -eq 1 -and $toTraefik[0].ports[0].port -eq 'websecure'
    if ((@($spec.policyTypes) -join ',') -eq 'Ingress,Egress' -and $inOk -and $outOk) { Pass "2b. hosted argocd-gate: in only from Traefik on http; out only DNS and Traefik's websecure port" }
    else { Fail "2b. hosted argocd-gate policy is wider than Traefik in, DNS + Traefik out: $(ConvertTo-Canonical $spec)" }
    if (Test-Selects $spec.podSelector $hosted) { Pass "2b. hosted argocd-gate policy selects the gate's pods" } else { Fail '2b. hosted argocd-gate policy selects no rendered pod' }
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
if (@($local | Where-Object { $_.metadata.name -eq 'argocd-gate' }).Count -eq 0) { Pass '4. local has no gate' } else { Fail '4. local renders the gate (envs/local stays as it is)' }

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) FAIL" -ForegroundColor Red; exit 1 }
Write-Host 'All passed.' -ForegroundColor Green
