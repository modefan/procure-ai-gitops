#Requires -Version 7.4
<#
.SYNOPSIS
    Installs Argo CD into the local cluster and hands it the system: deploy keys, repository Secrets, the root Application.
.DESCRIPTION
    Run after new-cluster.ps1, new-local-ca.ps1 and new-secrets.ps1. From then on Argo CD alone brings the system up and keeps it in
    line with git: the root Application renders apps/ (the app of apps) with envs/<Environment>/apps.yaml and envs/<Environment>/release.yaml, which
    creates the Applications argocd (Argo CD manages itself), platform, observability and procure-ai in sync waves.

    1. Deploy keys (plan 07 ruling 6), ed25519, private halves in %USERPROFILE%\.procure-ai\deploy-keys\ (current user only):
         argocd-procure-ai         read-only on modefan/procure-ai          (Argo CD reads the charts)
         argocd-procure-ai-gitops  read-only on modefan/procure-ai-gitops   (Argo CD reads the values and apps/)
         ci-gitops-write           write on modefan/procure-ai-gitops       (procure-ai's publish workflow bumps appRevision); its
                                   private half is the secret GITOPS_DEPLOY_KEY of the procure-ai
                                   Environment `gitops` (deployment branches: main only)
       A key is generated once and added to GitHub when GitHub does not list it; the Actions secret is set when the CI key is new or the
       secret is missing (-SetCiSecret sets it again). Needs `gh` signed in with admin rights on both repos.
    2. Argo CD by Helm (chart argo/argo-cd at the version in apps/values.yaml, values argocd/values.yaml), waiting until it runs.
    3. Repository Secrets repo-procure-ai and repo-procure-ai-gitops in namespace argocd (server-side apply, no value printed).
    4. The root Application.
    Safe to run again. Prints names and fingerprints only, never a key.
    The admin password of the Argo CD UI (https://argocd.procure.localtest.me, user admin) is in Secret argocd/argocd-initial-admin-secret.
    With argocd.adminEnabled / argocd.ingressEnabled false in envs/<Environment>/apps.yaml, Argo CD is installed without the admin user /
    its ingress from the start.
#>
[CmdletBinding()]
param(
    # The folder under envs/ to deploy.
    [string] $Environment = 'local',
    # Set the procure-ai Environment secret GITOPS_DEPLOY_KEY again even when it exists (after rotating the key by hand).
    [switch] $SetCiSecret
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ClusterReachable
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gh = Get-Gh

$appRepo = 'modefan/procure-ai'
$gitopsRepo = 'modefan/procure-ai-gitops'
$envDir = Join-Path $repoRoot "envs/$Environment"
foreach ($file in 'apps.yaml', 'release.yaml') {
    if (-not (Test-Path (Join-Path $envDir $file))) { throw "envs/$Environment/$file is missing." }
}

# --- 1. Deploy keys ------------------------------------------------------------------------------------------------------------------
Set-CurrentUserOnlyAcl $DeployKeyDir

function Get-DeployKeys([string] $repo) {
    $json = & $gh repo deploy-key list -R $repo --json key,readOnly,title 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh repo deploy-key list -R $repo failed: $json" }
    $text = ($json | ForEach-Object { "$_" }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    @($text | ConvertFrom-Json)
}

function Initialize-DeployKey([string] $name, [string] $repo, [bool] $write, [string] $title) {
    # Returns $true when the key was generated in this run.
    $path = Join-Path $DeployKeyDir $name
    $new = $false
    if (-not (Test-Path $path)) {
        $out = & ssh-keygen -q -t ed25519 -N '' -C $title -f $path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen for $name failed: $out" }
        Set-CurrentUserOnlyAcl $DeployKeyDir
        $new = $true
    }
    $public = (Get-Content -Raw "$path.pub").Trim()
    $publicKey = ($public -split '\s+')[0..1] -join ' '
    $listed = Get-DeployKeys $repo | Where-Object { (($_.key -split '\s+')[0..1] -join ' ') -eq $publicKey }
    if ($listed) {
        $listed = @($listed)[0]
        # gh 2.103 accepts --json readOnly but prints the API's field name read_only.
        $field = @('readOnly', 'read_only') | Where-Object { $listed.PSObject.Properties[$_] } | Select-Object -First 1
        $readOnly = if ($field) { [bool] $listed.$field } else { $null }
        if ($null -eq $readOnly) { throw "gh repo deploy-key list -R $repo returned no read-only flag (fields: $($listed.PSObject.Properties.Name -join ', '))." }
        if ($readOnly -eq $write) {
            throw "Deploy key $name is on $repo with the wrong access (read-only: $readOnly). Delete it on GitHub and run this script again."
        }
    } else {
        $addArgs = @('repo', 'deploy-key', 'add', "$path.pub", '-R', $repo, '--title', $title)
        if ($write) { $addArgs += '--allow-write' }
        $out = & $gh @addArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh repo deploy-key add ($name on $repo) failed: $out" }
        Write-Host "deploy key $name added to $repo ($(if ($write) { 'write' } else { 'read-only' }))"
    }
    $fingerprint = (& ssh-keygen -l -f "$path.pub" 2>&1) -join ' '
    Write-Host "deploy key ${name}: $($fingerprint.Split(' ')[1]) on $repo$(if ($new) { ' (new)' })"
    $new
}

Initialize-DeployKey 'argocd-procure-ai' $appRepo $false 'argocd-local (read-only)' | Out-Null
Initialize-DeployKey 'argocd-procure-ai-gitops' $gitopsRepo $false 'argocd-local (read-only)' | Out-Null
$ciKeyNew = Initialize-DeployKey 'ci-gitops-write' $gitopsRepo $true 'procure-ai publish workflow (write)'

# The CI key lives in the Environment `gitops` of procure-ai, which only the main branch may use (deployment branch policy), so a
# workflow run on any other branch cannot read it. publish.yml's deploy job and retention.yml name that Environment.
function Invoke-Gh([string] $what) {
    $out = & $gh @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$what failed: $out" }
    ($out | ForEach-Object { "$_" }) -join "`n"
}
$ghEnvironment = 'gitops'
'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
    & $gh api -X PUT "repos/$appRepo/environments/$ghEnvironment" --input - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "creating Environment $ghEnvironment on $appRepo failed." }
$policies = Invoke-Gh 'listing deployment branch policies' api "repos/$appRepo/environments/$ghEnvironment/deployment-branch-policies" --jq '[.branch_policies[] | .type + ":" + .name] | join(" ")'
if ($policies -notmatch '(^|\s)branch:main(\s|$)') {
    Invoke-Gh 'adding the main branch policy' api -X POST "repos/$appRepo/environments/$ghEnvironment/deployment-branch-policies" -f name=main -f type=branch | Out-Null
}
$policies = Invoke-Gh 'listing deployment branch policies' api "repos/$appRepo/environments/$ghEnvironment/deployment-branch-policies" --jq '[.branch_policies[] | .type + ":" + .name] | join(" ")'
if ($policies.Trim() -ne 'branch:main') { throw "Environment $ghEnvironment on $appRepo allows '$policies'; expected only branch:main. Fix it on GitHub (Settings, Environments)." }
Write-Host "Environment $ghEnvironment on $appRepo (deployment branches: main only)"

$envSecrets = Invoke-Gh 'gh secret list --env' secret list -R $appRepo --env $ghEnvironment --json name
$hasCiSecret = @(($envSecrets | ConvertFrom-Json) | Where-Object name -eq 'GITOPS_DEPLOY_KEY').Count -gt 0
if ($ciKeyNew -or $SetCiSecret -or -not $hasCiSecret) {
    # The value goes through stdin, never a command line or the console.
    $out = Get-Content -Raw (Join-Path $DeployKeyDir 'ci-gitops-write') | & $gh secret set GITOPS_DEPLOY_KEY -R $appRepo --env $ghEnvironment 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh secret set GITOPS_DEPLOY_KEY -R $appRepo --env $ghEnvironment failed: $out" }
    Write-Host "Environment secret GITOPS_DEPLOY_KEY set ($appRepo, $ghEnvironment)"
} else {
    Write-Host "Environment secret GITOPS_DEPLOY_KEY exists ($appRepo, $ghEnvironment)"
}
# A repository-level copy (before the Environment existed) would be readable from every branch: remove it.
$repoSecrets = Invoke-Gh 'gh secret list' secret list -R $appRepo --json name
if (@(($repoSecrets | ConvertFrom-Json) | Where-Object name -eq 'GITOPS_DEPLOY_KEY').Count -gt 0) {
    Invoke-Gh 'gh secret delete GITOPS_DEPLOY_KEY' secret delete GITOPS_DEPLOY_KEY -R $appRepo | Out-Null
    Write-Host "Repository secret GITOPS_DEPLOY_KEY removed from $appRepo (it is in Environment $ghEnvironment now)"
}

# --- 2. Argo CD ----------------------------------------------------------------------------------------------------------------------
# The chart version is the one the argocd Application uses afterwards (apps/values.yaml), so the hand-over changes nothing.
$appsValues = Get-Content -Raw (Join-Path $repoRoot 'apps/values.yaml')
if ($appsValues -notmatch '(?m)^\s+chartVersion:\s*"?([0-9][0-9A-Za-z.\-]*)"?\s*$') { throw 'argocd.chartVersion not found in apps/values.yaml.' }
$chartVersion = $Matches[1]
$chartRepo = 'https://argoproj.github.io/argo-helm'

# The environment's switches (argocd.adminEnabled, argocd.ingressEnabled: apps/values.yaml, overridden by envs/<env>/apps.yaml) as the
# argocd Application passes them (apps/templates/applications.yaml), so the first install is never more open than what follows it.
function Get-ArgoCdSwitch([string] $name) {
    $value = $true
    foreach ($file in (Join-Path $repoRoot 'apps/values.yaml'), (Join-Path $envDir 'apps.yaml')) {
        # Lines of the top-level `argocd:` block (from its line to the next top-level key).
        $inBlock = $false
        foreach ($line in Get-Content $file) {
            if ($line -match '^[A-Za-z]') { $inBlock = $line -match '^argocd:\s*(#.*)?$'; continue }
            if ($inBlock -and $line -match "^\s+$($name):\s*(true|false)\s*(#.*)?$") { $value = $Matches[1] -eq 'true' }
        }
    }
    $value
}
$adminEnabled = Get-ArgoCdSwitch 'adminEnabled'
$ingressEnabled = Get-ArgoCdSwitch 'ingressEnabled'

Write-Host "Installing Argo CD (chart argo-cd $chartVersion; admin user $(if ($adminEnabled) { 'on' } else { 'off' }), ingress $(if ($ingressEnabled) { 'on' } else { 'off' }))..."
$out = & helm --kube-context $KubeContext upgrade --install argocd argo-cd --repo $chartRepo --version $chartVersion `
    --namespace argocd -f (Join-Path $repoRoot 'argocd/values.yaml') `
    --set "configs.cm.admin\.enabled=$($adminEnabled.ToString().ToLowerInvariant())" `
    --set "server.ingress.enabled=$($ingressEnabled.ToString().ToLowerInvariant())" --wait --timeout 10m 2>&1
if ($LASTEXITCODE -ne 0) { throw "helm upgrade --install argocd failed: $($out -join [Environment]::NewLine)" }
Write-Host "Argo CD is running."

# --- 3. Repository Secrets -----------------------------------------------------------------------------------------------------------
foreach ($repo in @(
        @{ Name = 'repo-procure-ai'; Url = "git@github.com:$appRepo.git"; Key = 'argocd-procure-ai' },
        @{ Name = 'repo-procure-ai-gitops'; Url = "git@github.com:$gitopsRepo.git"; Key = 'argocd-procure-ai-gitops' })) {
    $secret = New-SecretObject -Namespace argocd -Name $repo.Name `
        -Data ([ordered]@{ type = 'git'; url = $repo.Url }) `
        -FileData ([ordered]@{ sshPrivateKey = (Join-Path $DeployKeyDir $repo.Key) })
    $secret.metadata.labels['argocd.argoproj.io/secret-type'] = 'repository'
    Write-Host (Invoke-Apply $secret)
}

# --- 4. The root Application -----------------------------------------------------------------------------------------------------------
$root = [ordered]@{
    apiVersion = 'argoproj.io/v1alpha1'
    kind       = 'Application'
    metadata   = [ordered]@{ name = 'root'; namespace = 'argocd'; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
    spec       = [ordered]@{
        project     = 'default'
        source      = [ordered]@{
            repoURL        = "git@github.com:$gitopsRepo.git"
            targetRevision = 'main'
            path           = 'apps'
            helm           = [ordered]@{ releaseName = 'root'; valueFiles = @("../envs/$Environment/apps.yaml", "../envs/$Environment/release.yaml") }
        }
        destination = [ordered]@{ server = 'https://kubernetes.default.svc'; namespace = 'argocd' }
        syncPolicy  = [ordered]@{
            automated   = [ordered]@{ prune = $true; selfHeal = $true }
            syncOptions = @('ServerSideApply=true')
            retry       = [ordered]@{ limit = 10; backoff = [ordered]@{ duration = '20s'; factor = 2; maxDuration = '3m' } }
        }
    }
}
Write-Host (Invoke-Apply $root)
Write-Host "Argo CD now brings up envs/$Environment (kubectl --context $KubeContext -n argocd get applications). UI: https://argocd.procure.localtest.me (admin; password in Secret argocd/argocd-initial-admin-secret)."
