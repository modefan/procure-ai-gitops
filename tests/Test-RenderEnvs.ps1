#Requires -Version 7.4
<#
.SYNOPSIS
    Renders every environment the way Argo CD will, before a values push to this repo (plan 08 final review B I1). No cluster needed.
.DESCRIPTION
    This repo has no CI (Argo CD reads it), so nothing else renders envs/<env>/*.yaml before Argo CD does on the cluster; for the hosted
    environment that is the public demo. For each environment (local and hosted, or -Environment):
      1. the app of apps (apps/) with envs/<env>/apps.yaml and release.yaml (appRevision and the platform image tags must pass its checks);
      2. procure-ai's charts procure-platform, procure-ai, procure-observability and (when envs/<env>/apps.yaml turns `operator` on, plan 08b
         Task 4) procure-ops, taken from the procure-ai clone at the environment's
         appRevision (git archive; -AppRef renders another commit or 'WORKTREE' for the clone's files as they are, e.g. an unpushed chart
         change), with envs/<env>/<chart values file> and the image tags the Application passes (global.imageTag = appRevision,
         global.imageTags = platformImageTags). Dependencies as Argo CD's repo-server resolves them: the chart is rendered as committed and
         `helm dependency build` runs only for a dependency missing from charts/ (the umbrella's file:// procure-app);
      3. Argo CD's own chart (apps/values.yaml chartRepo/chartVersion, OCI) with argocd/values.yaml, envs/<env>/argocd.yaml and the
         environment's switches; for an environment with argocd.ingressEnabled and a hostname other than the local one (hosted, plan 08c
         Task 1) also the public host's edge: the Ingress for that host with the middlewares rate limit, headers and the Keycloak gate
         (in that order), each Middleware rendered, the IngressRoute argocd-edge (403 for POST /api/v1/session and the gRPC-web session
         create, the cross-site guard, /oauth2/ to the gate) and the gate's Deployment (pinned image, memory limit, group argocd-admins).
    Every render goes through `kubeconform -strict`: Kubernetes schemas, and custom resources (Traefik's Middleware, Argo CD's) against the
    community CRD schema catalog (datreeio/CRDs-catalog); a custom resource neither knows is skipped and counted. Exit code 1 when a
    render or a validation fails.

    Run it before every push to this repo that changes envs/, apps/ or argocd/ (procure-ai docs/hosting.md, "Changing the hosted values"),
    and after a procure-ai chart change that needs new values (-AppRef WORKTREE in that change's worktree). procure-ai's CI charts job
    renders the same environments against each procure-ai commit (its "Render every chart with each GitOps environment's values" step).
    Needs helm and kubeconform on PATH and git. Prints no secret (no Secret values are in these files).
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'hosted')]
    [string[]] $Environment = @('local', 'hosted'),
    # The procure-ai clone or worktree the charts come from (default: the clone next to this repo, C:\Projects\2026\procure-ai).
    [string] $AppRepo = '',
    # The procure-ai commit to render (default: each environment's appRevision); WORKTREE renders the files of -AppRepo as they are.
    [string] $AppRef = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $AppRepo) {
    # This repo and procure-ai are siblings in C:\Projects\2026; a worktree of this repo sits one level deeper.
    $AppRepo = @((Join-Path $root '..\procure-ai'), (Join-Path $root '..\..\procure-ai')) | Where-Object { Test-Path (Join-Path $_ 'deploy/charts') } |
        Select-Object -First 1
    if (-not $AppRepo) { throw 'procure-ai clone not found next to this repo; pass -AppRepo.' }
}
$AppRepo = (Resolve-Path $AppRepo).Path
foreach ($tool in 'helm', 'kubeconform', 'git') { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH." } }

$failures = [System.Collections.Generic.List[string]]::new()
function Pass([string] $m) { Write-Host "  ok    $m" -ForegroundColor Green }
function Fail([string] $m) { $failures.Add($m); Write-Host "  FAIL  $m" -ForegroundColor Red }

function Read-Release([string] $file) {
    # release.yaml: appRevision and platformImageTags (flat, written by procure-ai's publish workflow).
    $text = Get-Content -Raw $file
    if ($text -notmatch '(?m)^appRevision:\s*"?([0-9a-f]{40})"?') { throw "$file has no 40-character appRevision." }
    $revision = $Matches[1]
    $tags = [ordered]@{}
    $in = $false
    foreach ($line in $text -split "`r?`n") {
        if ($line -match '^platformImageTags:') { $in = $true; continue }
        if ($in -and $line -match '^\s+([a-z0-9-]+):\s*"?([0-9a-f]{40})"?') { $tags[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^\S') { $in = $false }
    }
    [pscustomobject]@{ AppRevision = $revision; ImageTags = $tags }
}

function Invoke-Render([string] $label, [string[]] $helmArgs) {
    # helm template ... | kubeconform -strict; one PASS/FAIL line with the counts.
    # Only stdout is YAML: an OCI pull writes "Pulled: ..." and "Digest: ..." to stderr.
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & helm template @helmArgs 2>$errFile
        if ($LASTEXITCODE -ne 0) { Fail "$label`: helm template failed: $((Get-Content $errFile | Select-Object -First 5) -join ' ')"; return }
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
    $yaml = ($out | ForEach-Object { "$_" }) -join "`n"
    $crds = 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    $script:LastRender = $yaml
    $result = $yaml | & kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location $crds -summary -output text 2>&1
    $summary = ($result | Where-Object { "$_" -match '^Summary:' }) -join ''
    if ($LASTEXITCODE -ne 0) { Fail "$label`: kubeconform: $(($result | Select-Object -First 6) -join ' | ')"; return }
    Pass "$label`: $($summary -replace '^Summary:\s*', '')"
}

function Test-ArgocdEdge([string] $label, [string] $yaml) {
    # The public Argo CD host of an environment (plan 08c Task 1): what must be in the render, by kind and name. A missing field (strict
    # mode) is a FAIL with its message.
    try { Test-ArgocdEdgeDocs $label $yaml } catch { Fail "$label`: $($_.Exception.Message)" }
}
function Test-ArgocdEdgeDocs([string] $label, [string] $yaml) {
    $json = $yaml | & python -c 'import sys, yaml, json; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'
    if ($LASTEXITCODE -ne 0) { Fail "$label`: YAML to JSON (python, PyYAML) failed"; return }
    $docs = @(($json -join "`n") | ConvertFrom-Json -Depth 100)
    function Find([string] $kind, [string] $name) { @($docs | Where-Object { $_.kind -eq $kind -and $_.metadata.name -eq $name }) | Select-Object -First 1 }
    $ingress = Find 'Ingress' 'argocd-server'
    $hostName = "$($ingress.spec.rules[0].host)"
    if (-not $ingress -or -not $hostName) { Fail "$label`: no Ingress argocd-server with a host"; return }
    $middlewares = "$($ingress.metadata.annotations.'traefik.ingress.kubernetes.io/router.middlewares')"
    if ($middlewares -eq 'argocd-edge-ratelimit@kubernetescrd,argocd-edge-headers@kubernetescrd,argocd-edge-gate@kubernetescrd') {
        Pass "$label`: Ingress $hostName with rate limit, headers and the Keycloak gate"
    } else { Fail "$label`: Ingress $hostName middlewares '$middlewares' (expected rate limit, headers, gate)" }
    foreach ($name in 'edge-ratelimit', 'edge-headers', 'edge-gate', 'edge-deny') {
        if (-not (Find 'Middleware' $name)) { Fail "$label`: Middleware $name missing" }
    }
    $gateMw = Find 'Middleware' 'edge-gate'
    if ($gateMw -and "$($gateMw.spec.forwardAuth.address)" -eq 'http://argocd-gate.argocd.svc.cluster.local:4180/') { Pass "$label`: forwardAuth to the gate (argocd-gate:4180)" }
    else { Fail "$label`: Middleware edge-gate is not a forwardAuth to http://argocd-gate.argocd.svc.cluster.local:4180/" }
    $route = Find 'IngressRoute' 'argocd-edge'
    if (-not $route) { Fail "$label`: IngressRoute argocd-edge missing"; return }
    $routes = @($route.spec.routes)
    $session = @($routes | Where-Object { $_.match -match [regex]::Escape("Host(``$hostName``)") -and $_.match -match 'Method\(`POST`\) && PathRegexp\(`\^/api/v1/session/\?\$`\)' -and $_.match -match 'PathPrefix\(`/session\.SessionService/`\)' })
    $denies = { param($r) @($r.middlewares | ForEach-Object { $_.name }) -contains 'edge-deny' -and $r.services[0].name -eq 'noop@internal' }
    if ($session.Count -eq 1 -and (& $denies $session[0]) -and [int] $session[0].priority -gt 10000) { Pass "$label`: POST /api/v1/session and the gRPC-web session create answer 403 (edge-deny, priority $($session[0].priority))" }
    else { Fail "$label`: no high-priority 403 route for POST /api/v1/session and /session.SessionService/" }
    $origin = @($routes | Where-Object { $_.match -match 'HeaderRegexp\(`Origin`' -and $_.match -match [regex]::Escape("!Header(``Origin``, ``https://$hostName``)") })
    if ($origin.Count -eq 1 -and (& $denies $origin[0])) { Pass "$label`: cross-site requests (foreign Origin) answer 403" } else { Fail "$label`: no cross-site guard route" }
    $oauth = @($routes | Where-Object { $_.match -match 'PathPrefix\(`/oauth2/`\)' })
    if ($oauth.Count -eq 1 -and $oauth[0].services[0].name -eq 'argocd-gate' -and -not (@($oauth[0].middlewares | ForEach-Object { $_.name }) -contains 'edge-gate')) {
        Pass "$label`: /oauth2/ goes to the gate itself (no forwardAuth)"
    } else { Fail "$label`: no /oauth2/ route to the gate" }
    $deploy = Find 'Deployment' 'argocd-gate'
    $container = if ($deploy) { $deploy.spec.template.spec.containers[0] } else { $null }
    $cargs = @($container.args)
    $ok = $container -and "$($container.image)" -match '^quay\.io/oauth2-proxy/oauth2-proxy:v\d+\.\d+\.\d+$' -and "$($container.resources.limits.memory)" -and
        '--allowed-group=argocd-admins' -in $cargs -and '--client-id=argocd-gate' -in $cargs -and '--code-challenge-method=S256' -in $cargs -and
        "--redirect-url=https://$hostName/oauth2/callback" -in $cargs -and '--upstream=static://202' -in $cargs -and
        '--cookie-secure=true' -in $cargs -and '--insecure-oidc-skip-nonce=false' -in $cargs
    if ($ok) { Pass "$label`: gate Deployment ($($container.image), memory limit $($container.resources.limits.memory), group argocd-admins only)" }
    else { Fail "$label`: gate Deployment argocd-gate missing or not as expected (pinned oauth2-proxy image, memory limit, argocd-gate client with PKCE, group argocd-admins)" }
}

function Export-Charts([string] $ref) {
    # procure-ai's deploy/charts at $ref into a temporary folder (WORKTREE: a copy of the files as they are).
    $dir = Join-Path ([IO.Path]::GetTempPath()) "procure-render-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    if ($ref -eq 'WORKTREE') {
        Copy-Item -Recurse (Join-Path $AppRepo 'deploy') $dir
        # Built dependencies of the worktree are not what Argo CD sees: keep only committed-style archives (the collector), drop built ones.
        Get-ChildItem (Join-Path $dir 'deploy/charts/procure-ai/charts') -Filter *.tgz -ErrorAction SilentlyContinue | Remove-Item
    } else {
        & git -C $AppRepo cat-file -e "$ref^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { & git -C $AppRepo fetch --quiet origin 2>&1 | Out-Null }
        & git -C $AppRepo cat-file -e "$ref^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "procure-ai commit $ref is not in $AppRepo (even after git fetch)." }
        $archive = Join-Path $dir 'charts.tar'
        & git -C $AppRepo archive --format=tar -o $archive $ref deploy/charts
        if ($LASTEXITCODE -ne 0) { throw "git archive $ref deploy/charts failed." }
        # Windows' own tar (bsdtar): a GNU tar from Git's tools reads 'C:' in the path as a remote host.
        $tar = @("$env:SystemRoot\System32\tar.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($tar) { & $tar -xf $archive -C $dir } else { & tar --force-local -xf $archive -C $dir }
        if ($LASTEXITCODE -ne 0) { throw 'tar -xf failed.' }
        Remove-Item $archive
    }
    $dir
}

function Resolve-Dependencies([string] $chart) {
    # As Argo CD's repo-server: render as committed; only a dependency missing from charts/ makes it run `helm dependency build`.
    $probe = & helm template probe $chart 2>&1
    if ($LASTEXITCODE -eq 0 -or -not (($probe -join ' ') -match 'missing in charts/ directory')) { return 'as committed' }
    $out = & helm dependency build $chart --skip-refresh 2>&1
    if ($LASTEXITCODE -ne 0) { throw "helm dependency build $chart failed: $($out -join ' ')" }
    'helm dependency build (missing from charts/)'
}

$appsValues = Get-Content -Raw (Join-Path $root 'apps/values.yaml')
$argoRepo = [regex]::Match($appsValues, '(?m)^\s+chartRepo:\s*"?([^"\s#]+)').Groups[1].Value
$argoVersion = [regex]::Match($appsValues, '(?m)^\s+chartVersion:\s*"?([0-9][^"\s#]*)').Groups[1].Value
$argoChart = if ($argoRepo -match '://') { $null } else { "oci://$argoRepo/argo-cd" }

$charts = @(
    @{ Name = 'platform'; Path = 'procure-platform'; Values = 'platform.yaml'; Namespace = 'procure' }
    @{ Name = 'procure-ai'; Path = 'procure-ai'; Values = 'procure-ai.yaml'; Namespace = 'procure' }
    @{ Name = 'observability'; Path = 'procure-observability'; Values = 'observability.yaml'; Namespace = 'observability' }
    # Only where envs/<env>/apps.yaml has `operator: enabled: true` (apps/values.yaml: off by default).
    @{ Name = 'operator'; Path = 'procure-ops'; Values = 'operator.yaml'; Namespace = 'operator'; Switch = 'operator' }
)
function Test-AppEnabled([string] $envDir, [string] $key) {
    # The Application's `enabled` in envs/<env>/apps.yaml over apps/values.yaml (false there for every switchable Application).
    $value = $false
    foreach ($file in (Join-Path $root 'apps/values.yaml'), (Join-Path $envDir 'apps.yaml')) {
        $block = [regex]::Match((Get-Content -Raw $file), "(?ms)^$($key):\s*\r?\n(.*?)(?=^\S|\z)").Groups[1].Value
        $m = [regex]::Match($block, '(?m)^\s+enabled:\s*(true|false)\s*(#.*)?$')
        if ($m.Success) { $value = $m.Groups[1].Value -eq 'true' }
    }
    $value
}
$exports = @{}
try {
    foreach ($env in $Environment) {
        $envDir = Join-Path $root "envs/$env"
        $release = Read-Release (Join-Path $envDir 'release.yaml')
        $ref = if ($AppRef) { $AppRef } else { $release.AppRevision }
        Write-Host "`n== envs/$env (procure-ai $(if ($ref -eq 'WORKTREE') { "files of $AppRepo" } else { $ref.Substring(0, [Math]::Min(12, $ref.Length)) }))" -ForegroundColor Cyan

        # 1. The app of apps.
        Invoke-Render "apps ($env)" @('apps', (Join-Path $root 'apps'), '--namespace', 'argocd', '-f', (Join-Path $envDir 'apps.yaml'), '-f', (Join-Path $envDir 'release.yaml'))

        # 2. procure-ai's charts at the revision, with the values the Application passes.
        if (-not $exports.ContainsKey($ref)) {
            $exports[$ref] = Export-Charts $ref
            foreach ($c in $charts) {
                if (-not (Test-Path (Join-Path $exports[$ref] "deploy/charts/$($c.Path)"))) { continue }
                $how = Resolve-Dependencies (Join-Path $exports[$ref] "deploy/charts/$($c.Path)")
                Write-Host "        dependencies of $($c.Path): $how"
            }
        }
        $sets = @('--set', "global.imageTag=$($release.AppRevision)")
        foreach ($name in $release.ImageTags.Keys) { $sets += @('--set', "global.imageTags.$name=$($release.ImageTags[$name])") }
        foreach ($c in $charts) {
            if ($c['Switch'] -and -not (Test-AppEnabled $envDir $c['Switch'])) { Write-Host "skip:   $($c.Name) ($env): off in envs/$env/apps.yaml"; continue }
            $chartDir = Join-Path $exports[$ref] "deploy/charts/$($c.Path)"
            # A chart the release's procure-ai commit does not have yet: Argo CD's Application would fail the same way (push procure-ai
            # and let its publish workflow write release.yaml first).
            if (-not (Test-Path $chartDir)) { Fail "$($c.Name) ($env): procure-ai $ref has no deploy/charts/$($c.Path), but envs/$env/apps.yaml turns it on"; continue }
            Invoke-Render "$($c.Name) ($env)" (@($c.Name, $chartDir, '--namespace', $c.Namespace, '-f', (Join-Path $envDir $c.Values)) + $sets)
        }

        # 3. Argo CD's own chart with the environment's values and switches (as apps/templates/applications.yaml passes them).
        if (-not $argoChart -or -not $argoVersion) { Fail "argocd: chartRepo '$argoRepo' / chartVersion '$argoVersion' in apps/values.yaml (expected an OCI registry without scheme)"; continue }
        $switch = @{}
        foreach ($name in 'adminEnabled', 'ingressEnabled') {
            $value = 'true'
            foreach ($file in (Join-Path $root 'apps/values.yaml'), (Join-Path $envDir 'apps.yaml')) {
                $block = [regex]::Match((Get-Content -Raw $file), '(?ms)^argocd:\s*\r?\n(.*?)(?=^\S|\z)').Groups[1].Value
                $m = [regex]::Match($block, "(?m)^\s+$($name):\s*(true|false)\s*(#.*)?$")
                if ($m.Success) { $value = $m.Groups[1].Value }
            }
            $switch[$name] = $value
        }
        $script:LastRender = ''
        Invoke-Render "argocd ($env, chart $argoVersion)" @('argocd', $argoChart, '--version', $argoVersion, '--namespace', 'argocd',
            '-f', (Join-Path $root 'argocd/values.yaml'), '-f', (Join-Path $envDir 'argocd.yaml'),
            '--set', "configs.cm.admin\.enabled=$($switch.adminEnabled)", '--set', "server.ingress.enabled=$($switch.ingressEnabled)")
        # The public host's edge and gate (plan 08c Task 1): every environment but local (whose Argo CD is behind the local CA's wildcard).
        if ($env -ne 'local') {
            if ($switch.ingressEnabled -ne 'true') { Fail "argocd ($env): argocd.ingressEnabled is not true (plan 08c Task 1: the public host behind the Keycloak gate)" }
            elseif ($script:LastRender) { Test-ArgocdEdge "argocd edge ($env)" $script:LastRender }
        }
    }
} finally {
    foreach ($dir in $exports.Values) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}

if ($failures.Count) { Write-Host "`n$($failures.Count) render(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nEvery environment renders and validates." -ForegroundColor Green
exit 0
