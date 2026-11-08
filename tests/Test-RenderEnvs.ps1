#Requires -Version 7.4
<#
.SYNOPSIS
    Renders every environment the way Argo CD will, before a values push to this repo (plan 08 final review B I1). No cluster needed.
.DESCRIPTION
    This repo has no CI (Argo CD reads it), so nothing else renders envs/<env>/*.yaml before Argo CD does on the cluster; for the hosted
    environment that is the public demo. For each environment (local and hosted, or -Environment):
      1. the app of apps (apps/) with envs/<env>/apps.yaml and release.yaml (appRevision and the platform image tags must pass its checks);
      2. procure-ai's charts procure-platform, procure-ai and procure-observability, taken from the procure-ai clone at the environment's
         appRevision (git archive; -AppRef renders another commit or 'WORKTREE' for the clone's files as they are, e.g. an unpushed chart
         change), with envs/<env>/<chart values file> and the image tags the Application passes (global.imageTag = appRevision,
         global.imageTags = platformImageTags). Dependencies as Argo CD's repo-server resolves them: the chart is rendered as committed and
         `helm dependency build` runs only for a dependency missing from charts/ (the umbrella's file:// procure-app);
      3. Argo CD's own chart (apps/values.yaml chartRepo/chartVersion, OCI) with argocd/values.yaml, envs/<env>/argocd.yaml and the
         environment's switches.
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
    $result = $yaml | & kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location $crds -summary -output text 2>&1
    $summary = ($result | Where-Object { "$_" -match '^Summary:' }) -join ''
    if ($LASTEXITCODE -ne 0) { Fail "$label`: kubeconform: $(($result | Select-Object -First 6) -join ' | ')"; return }
    Pass "$label`: $($summary -replace '^Summary:\s*', '')"
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
)
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
                $how = Resolve-Dependencies (Join-Path $exports[$ref] "deploy/charts/$($c.Path)")
                Write-Host "        dependencies of $($c.Path): $how"
            }
        }
        $sets = @('--set', "global.imageTag=$($release.AppRevision)")
        foreach ($name in $release.ImageTags.Keys) { $sets += @('--set', "global.imageTags.$name=$($release.ImageTags[$name])") }
        foreach ($c in $charts) {
            $chartDir = Join-Path $exports[$ref] "deploy/charts/$($c.Path)"
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
        Invoke-Render "argocd ($env, chart $argoVersion)" @('argocd', $argoChart, '--version', $argoVersion, '--namespace', 'argocd',
            '-f', (Join-Path $root 'argocd/values.yaml'), '-f', (Join-Path $envDir 'argocd.yaml'),
            '--set', "configs.cm.admin\.enabled=$($switch.adminEnabled)", '--set', "server.ingress.enabled=$($switch.ingressEnabled)")
    }
} finally {
    foreach ($dir in $exports.Values) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}

if ($failures.Count) { Write-Host "`n$($failures.Count) render(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nEvery environment renders and validates." -ForegroundColor Green
exit 0
