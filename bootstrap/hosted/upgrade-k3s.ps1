#Requires -Version 7.4
<#
.SYNOPSIS
    Upgrades k3s on the hosted VM to a newer patch release (plan 08 final review B I3), or (the default) only shows what an upgrade would
    change. procure-ai docs/hosting.md, "Upgrading the node", is the runbook around it.
.DESCRIPTION
    k3s ships its own containerd, runc, Traefik, CoreDNS, flannel and metrics-server; unattended upgrades cover Ubuntu's packages only, so
    an internet-facing node gets their security fixes only through a k3s upgrade. Plan (default, read-only):
      - the version running on the VM (k3s --version over SSH) and the pin bootstrap/common.ps1 HostedK3sVersion;
      - the target: -Version, or the newest stable patch of the running minor from GitHub's k3s releases (a minor upgrade is never
        picked by itself: read the Kubernetes and k3s upgrade notes first and pass -Version);
      - the embedded component versions of both releases (the release notes' table), and a warning when Traefik's major or minor
        changes (the bundled chart's values schema may change: check bootstrap/hosted/traefik-config.yaml against the chart's notes).
    -Apply (one node, so a few seconds without API; the pods keep running while k3s restarts, containerd's shims hold them):
      1. sets the version in /usr/local/sbin/install-k3s.sh (cloud-init's pinned installer) and runs it: the release's install.sh, which
         checks the binary's sha256 against the release's checksums and restarts k3s with the same /etc/rancher/k3s/config.yaml;
      2. waits until the node is Ready on the new version;
      3. fetches the kubeconfig again (new-hosted-cluster.ps1 -KubeconfigOnly; k3s renews its client certificates on a restart when they
         are close to expiry, and the PC's copy would stop working);
      4. runs Test-HostBaseline.ps1: its AppArmor probe proves the runc profile attaches to the new data/<hash>/bin/runc, and its k3s check
         FAILS until HostedK3sVersion in bootstrap/common.ps1 is updated (the reminder to commit the new pin; keep cloud-init.yaml in line,
         new-hosted-cluster.ps1 passes the pin to it).
    Afterwards (docs/hosting.md): install-cert-manager.ps1 -Production (re-applies traefik-config.yaml and waits for Traefik's rollout),
    tests/Test-PublicSurface.ps1 and tests/Test-FreshCluster.ps1 -Environment hosted -WatchOnly.
    Prints no secret.
#>
[CmdletBinding()]
param(
    # The k3s release to install, e.g. v1.35.11+k3s1 (default: the newest stable patch of the running minor).
    [ValidatePattern('^v1\.\d+\.\d+\+k3s\d+$')] [string] $Version = '',
    # Really upgrade; without it the script only plans.
    [switch] $Apply
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$hostInfo = Get-HostedHost

function Get-K3sRelease([string] $tag) {
    Invoke-RestMethod -Headers @{ 'User-Agent' = 'procure-bootstrap'; Accept = 'application/vnd.github+json' } `
        "https://api.github.com/repos/k3s-io/k3s/releases/tags/$([uri]::EscapeDataString($tag))"
}
function Get-Components($release) {
    # The release notes' "Embedded Component Versions" table: component -> version.
    $components = [ordered]@{}
    foreach ($m in [regex]::Matches($release.body, '(?m)^\|\s*([A-Za-z][A-Za-z -]*?)\s*\|\s*\[([^\]]+)\]')) { $components[$m.Groups[1].Value] = $m.Groups[2].Value }
    $components
}

$running = ((Invoke-HostedSsh -Command 'k3s --version | head -1') -join '') -replace '^k3s version (\S+).*$', '$1'
if ($running -notmatch '^v(\d+)\.(\d+)\.\d+\+k3s\d+$') { throw "Unexpected k3s version on the VM: '$running'." }
$minor = "v$($Matches[1]).$($Matches[2])."
if (-not $Version) {
    $releases = Invoke-RestMethod -Headers @{ 'User-Agent' = 'procure-bootstrap' } 'https://api.github.com/repos/k3s-io/k3s/releases?per_page=100'
    $Version = @($releases | Where-Object { -not $_.prerelease -and -not $_.draft -and $_.tag_name.StartsWith($minor) -and $_.tag_name -match '^v\d+\.\d+\.\d+\+k3s\d+$' } |
        Sort-Object { [version] ($_.tag_name -replace '^v(\d+\.\d+\.\d+)\+k3s(\d+)$', '$1.$2') } -Descending)[0].tag_name
}
Write-Host "k3s on the VM: $running; pinned in bootstrap/common.ps1: $HostedK3sVersion; target: $Version."
if ($running -ne $HostedK3sVersion) { Write-Warning "The VM runs $running but common.ps1 pins ${HostedK3sVersion}: update the pin (or the VM) first." }

$target = Get-K3sRelease $Version
if ($target.prerelease -or $target.draft) { throw "$Version is a pre-release." }
$now = Get-Components (Get-K3sRelease $running)
$next = Get-Components $target
Write-Host ("{0,-24} {1,-28} {2}" -f 'Component', $running, $Version)
foreach ($name in $next.Keys) {
    $mark = if ($now[$name] -ne $next[$name]) { '  <- changes' } else { '' }
    Write-Host ("{0,-24} {1,-28} {2}{3}" -f $name, $now[$name], $next[$name], $mark)
}
$traefikNow = [regex]::Match("$($now['Traefik'])", '^v?(\d+)\.(\d+)'); $traefikNext = [regex]::Match("$($next['Traefik'])", '^v?(\d+)\.(\d+)')
if ($traefikNow.Success -and $traefikNext.Success -and $traefikNow.Value -ne $traefikNext.Value) {
    Write-Warning "Traefik moves from $($now['Traefik']) to $($next['Traefik']): check the bundled chart's upgrade notes against bootstrap/hosted/traefik-config.yaml (hostPorts, redirections, middlewares, ingressEndpoint, resources) before -Apply."
}
if ($Version -eq $running) { Write-Host 'The VM already runs the target release: nothing to do.'; return }
$asVersion = { param($v) [version] ($v -replace '^v(\d+\.\d+\.\d+)\+k3s(\d+)$', '$1.$2') }
if ((& $asVersion $Version) -lt (& $asVersion $running)) { throw "$Version is older than ${running}: k3s does not support downgrades (a reinstall would be the way back)." }
if (-not $Version.StartsWith($minor)) { Write-Warning "$Version is a different minor than ${running}: read the Kubernetes and k3s upgrade notes; k3s supports one minor at a time." }
if (-not $Apply) {
    Write-Host "Plan only. To upgrade: ./bootstrap/hosted/upgrade-k3s.ps1 -Version $Version -Apply (then the steps in procure-ai docs/hosting.md, 'Upgrading the node')."
    return
}

# --- Apply -----------------------------------------------------------------------------------------------------------------------------
Write-Host "Upgrading k3s on $($hostInfo.ipv4) to $Version (the API is away for a few seconds; pods keep running)..."
# The installer's exit code decides (not tail's): its output goes to a log, the last lines are shown, and a failure throws here at once
# instead of after the 5-minute Ready wait.
$out = Invoke-HostedSsh -AllowFailure -Command "sudo sed -i ""s/^version='.*'$/version='$Version'/"" /usr/local/sbin/install-k3s.sh && grep -q ""^version='$Version'$"" /usr/local/sbin/install-k3s.sh && { sudo /usr/local/sbin/install-k3s.sh > /tmp/k3s-upgrade.log 2>&1; rc=`$?; tail -5 /tmp/k3s-upgrade.log; exit `$rc; }"
$rc = $LASTEXITCODE
$out | ForEach-Object { Write-Host "  $_" }
if ($rc -ne 0) { throw "The k3s install script failed (exit $rc; full log: /tmp/k3s-upgrade.log on the VM). k3s may still run the old release: check sudo systemctl status k3s." }
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    $state = (Invoke-HostedSsh -AllowFailure -Command "k3s --version | head -1; sudo k3s kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion} {.items[0].status.conditions[?(@.type==""Ready"")].status}'") -join ' '
    if ($state -match [regex]::Escape($Version) -and $state -match 'True$') { Write-Host "Node Ready on $Version."; break }
    if ((Get-Date) -gt $deadline) { throw "The node is not Ready on $Version within 5 minutes ($state); see sudo journalctl -u k3s on the VM." }
    Start-Sleep -Seconds 10
}
& (Join-Path $PSScriptRoot 'new-hosted-cluster.ps1') -KubeconfigOnly
& (Join-Path $PSScriptRoot 'Test-HostBaseline.ps1')
Write-Host "Next: set HostedK3sVersion = '$Version' in bootstrap/common.ps1 (Test-HostBaseline's k3s check fails until then) and commit; then install-cert-manager.ps1 -Production, tests/Test-PublicSurface.ps1, tests/Test-FreshCluster.ps1 -Environment hosted -WatchOnly."
