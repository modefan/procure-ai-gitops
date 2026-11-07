#Requires -Version 7.4
<#
.SYNOPSIS
    Creates (or checks) the hosted VM on Hetzner Cloud with Terraform (infra/hetzner), waits for cloud-init to install k3s, fetches the
    kubeconfig, opens the SSH tunnel and creates the namespaces. Then: new-secrets.ps1 -Environment hosted, install-argocd.ps1
    -Environment hosted.
.DESCRIPTION
    Needs terraform, ssh/ssh-keygen (Windows OpenSSH) and the Hetzner API token in the user env var HCLOUD_TOKEN (project procure-ai).
    Everything that is not code stays in %USERPROFILE%\.procure-ai\hosted\ (current user only; DEMO PASSWORDS.txt lists the names):
      procure-hosted_ed25519(.pub)  the VM's SSH key (generated once)
      terraform.tfstate             the Terraform state (local backend, given at init: never in the repo)
      tfplan                        the last plan (applied only after the guard below accepted it)
      host.json                     server ID, addresses, SSH user (from the Terraform outputs)
      known_hosts                   the VM's host key, recorded on the first connection
      kubeconfig                    context procure-hosted, server https://127.0.0.1:16443 (the tunnel)
    Money guard: the plan may hold only the expected resources (SSH key, network, subnet, firewall with 22/80/443 in, one cx43 server in
    fsn1). Anything else, or a replacement of the server, stops the script before apply (-AllowReplace for a deliberate recreate).
    Safe to run again: with nothing to change, Terraform applies nothing and the rest is re-checked.
    A stopped server still bills; `terraform destroy` (see procure-ai docs/hosting.md) removes it and pauses the cost.
#>
[CmdletBinding()]
param(
    # Stop after the plan (and its guard).
    [switch] $PlanOnly,
    # Apply without asking (the guard still runs).
    [switch] $AutoApprove,
    # Allow a plan that replaces the server (it loses all its data). Only when recreating the VM on purpose.
    [switch] $AllowReplace
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra\hetzner'

foreach ($tool in 'terraform', 'ssh', 'ssh-keygen', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
}
# The provider reads HCLOUD_TOKEN from the environment; a shell started before the variable was set does not have it yet.
if (-not $env:HCLOUD_TOKEN) { $env:HCLOUD_TOKEN = [Environment]::GetEnvironmentVariable('HCLOUD_TOKEN', 'User') }
if (-not $env:HCLOUD_TOKEN) { throw 'The user env var HCLOUD_TOKEN (Hetzner API token, DEMO PASSWORDS.txt) is not set.' }

function Invoke-Terraform {
    $out = & terraform "-chdir=$tfDir" @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "terraform $($args -join ' ') failed: $($out -join [Environment]::NewLine)" }
    $out | ForEach-Object { "$_" }
}

# --- 1. The SSH key ----------------------------------------------------------------------------------------------------------------------
Set-CurrentUserOnlyAcl $HostedDir
if (-not (Test-Path $HostedSshKey)) {
    $out = & ssh-keygen -q -t ed25519 -N '' -C 'procure-hosted admin' -f $HostedSshKey 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed: $out" }
    Set-CurrentUserOnlyAcl $HostedDir
    Write-Host "SSH key generated: $HostedSshKey(.pub)"
}
$fingerprint = ((& ssh-keygen -l -f "$HostedSshKey.pub" 2>&1) -join ' ').Split(' ')[1]
Write-Host "SSH key: $fingerprint"

# --- 2. Plan, guard, apply -----------------------------------------------------------------------------------------------------------------
Invoke-Terraform init -input=false -no-color "-backend-config=path=$HostedStateFile" | Out-Null
$planFile = Join-Path $HostedDir 'tfplan'
$tfVars = @('-var', "ssh_public_key_path=$HostedSshKey.pub", '-var', "k3s_version=$HostedK3sVersion")
Invoke-Terraform plan -input=false -no-color "-out=$planFile" @tfVars | Out-Null
$plan = (Invoke-Terraform show -json $planFile) -join "`n" | ConvertFrom-Json -Depth 50

$expected = @('hcloud_firewall.public', 'hcloud_network.private', 'hcloud_network_subnet.private', 'hcloud_server.node', 'hcloud_ssh_key.admin')
$problems = [System.Collections.Generic.List[string]]::new()
$changes = @($plan.resource_changes | Where-Object { (@($_.change.actions) -join ',') -ne 'no-op' })
foreach ($rc in $plan.resource_changes) {
    if ($rc.address -notin $expected) { $problems.Add("unexpected resource $($rc.address) ($($rc.change.actions -join '/'))") }
}
$server = $plan.resource_changes | Where-Object address -eq 'hcloud_server.node'
if ($server) {
    $after = $server.change.after
    if ($after.server_type -ne 'cx43') { $problems.Add("server type $($after.server_type), approved is cx43") }
    if ($after.location -ne 'fsn1') { $problems.Add("location $($after.location), approved is fsn1") }
    if ('delete' -in $server.change.actions -and -not $AllowReplace) { $problems.Add('the plan deletes or replaces the server (all its data); rerun with -AllowReplace only on purpose') }
}
$firewall = $plan.resource_changes | Where-Object address -eq 'hcloud_firewall.public'
if ($firewall -and $firewall.change.after) {
    $rules = @($firewall.change.after.rule | ForEach-Object { "$($_.direction)/$($_.protocol)/$($_.port)" } | Sort-Object)
    if (($rules -join ',') -ne 'in/tcp/22,in/tcp/443,in/tcp/80') { $problems.Add("firewall rules are $($rules -join ', '), expected in/tcp 22, 80, 443 only") }
}
foreach ($rc in $changes) { Write-Host "plan: $($rc.change.actions -join '/') $($rc.address)" }
if ($problems.Count -gt 0) { throw "Plan rejected (nothing applied):`n  $($problems -join "`n  ")" }
Write-Host "Plan accepted: $($changes.Count) change(s); only the expected resources, one cx43 server in fsn1."
if ($PlanOnly) { return }

if ($changes.Count -gt 0) {
    if (-not $AutoApprove) {
        $answer = Read-Host 'Apply this plan? The server bills about EUR 19 a month while it exists (type yes)'
        if ($answer -ne 'yes') { Write-Host 'Not applied.'; return }
    }
    Invoke-Terraform apply -input=false -no-color $planFile | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
}
Remove-Item $planFile -ErrorAction SilentlyContinue

$outputs = (Invoke-Terraform output -json) -join "`n" | ConvertFrom-Json
$hostInfo = [ordered]@{
    serverId  = $outputs.server_id.value
    type      = $outputs.server_type.value
    location  = $outputs.location.value
    ipv4      = $outputs.ipv4_address.value
    ipv6      = $outputs.ipv6_address.value
    privateIp = $outputs.private_ip.value
    user      = $outputs.admin_user.value
}
$hostInfo | ConvertTo-Json | Set-Content -Path $HostedHostFile
Write-Host "Server $($hostInfo.serverId) ($($hostInfo.type), $($hostInfo.location)): $($hostInfo.ipv4) / $($hostInfo.ipv6), private $($hostInfo.privateIp)"

# --- 3. First SSH contact, cloud-init --------------------------------------------------------------------------------------------------
# The host key is recorded on the first connection (trust on first use: the server is minutes old and reached at the address Terraform
# just got from the Hetzner API); later connections require the same key (StrictHostKeyChecking=yes in Get-HostedSshArgs).
$target = "$($hostInfo.user)@$($hostInfo.ipv4)"
$known = (Test-Path $HostedKnownHosts) -and ((& ssh-keygen -F $hostInfo.ipv4 -f $HostedKnownHosts 2>$null) -join '') -ne ''
$deadline = (Get-Date).AddMinutes(10)
while ($true) {
    $firstArgs = @(Get-HostedSshArgs) | ForEach-Object { if ($_ -eq 'StrictHostKeyChecking=yes' -and -not $known) { 'StrictHostKeyChecking=accept-new' } else { $_ } }
    $out = & ssh @firstArgs $target 'true' 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw "SSH to $target did not work within 10 minutes: $($out -join ' ')" }
    Start-Sleep -Seconds 10
}
Write-Host "SSH works ($target); host key in $HostedKnownHosts."
$status = Invoke-HostedSsh -Command 'cloud-init status --wait >/dev/null 2>&1; cloud-init status --long' -AllowFailure
Write-Host ($status -join "`n")
if (-not ($status -match '^status: done')) { throw 'cloud-init did not finish cleanly (see above; sudo cat /var/log/cloud-init-output.log on the VM).' }

# --- 4. kubeconfig (through the tunnel) -----------------------------------------------------------------------------------------------
$raw = & ssh @(Get-HostedSshArgs) $target 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Could not read /etc/rancher/k3s/k3s.yaml on the VM (is k3s running? sudo systemctl status k3s).' }
$kubeconfig = ($raw -join "`n") -replace '(?m)^(\s*server:\s*)https://\S+$', "`${1}https://127.0.0.1:$HostedTunnelPort" `
    -replace '(?m)^(\s*(name|cluster|user|current-context):\s*)default\s*$', "`${1}$HostedKubeContext"
Set-Content -Path $HostedKubeconfig -Value $kubeconfig -NoNewline
Set-CurrentUserOnlyAcl $HostedDir
Remove-Variable raw, kubeconfig
Write-Host "kubeconfig: $HostedKubeconfig (context $HostedKubeContext, via the tunnel)"

Select-ProcureCluster 'hosted'
Assert-ClusterReachable
foreach ($ns in $Namespaces) { Write-Host (Invoke-Apply (New-NamespaceObject $ns)) }
$node = (Invoke-Kubectl get nodes -o json | Out-String | ConvertFrom-Json).items[0]
Write-Host "Node $($node.metadata.name): $($node.status.nodeInfo.kubeletVersion), $($node.status.nodeInfo.osImage), Ready=$(($node.status.conditions | Where-Object type -eq Ready).status)"
Write-Host 'Next: bootstrap/new-secrets.ps1 -Environment hosted, then bootstrap/install-argocd.ps1 -Environment hosted. Check with bootstrap/hosted/Test-HostBaseline.ps1.'
