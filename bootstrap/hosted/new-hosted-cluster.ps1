#Requires -Version 7.4
<#
.SYNOPSIS
    Creates (or checks, or destroys) the hosted setup with Terraform (infra/hetzner): the Hetzner VM with k3s (cloud-init), its firewall,
    private network and SSH key, and the Cloudflare DNS records procure/auth/dashboard.daleabels.com. Then waits for cloud-init, fetches
    the kubeconfig, opens the SSH tunnel and creates the namespaces. Next: new-secrets.ps1 -Environment hosted, install-argocd.ps1
    -Environment hosted.
.DESCRIPTION
    Needs terraform, ssh/ssh-keygen (Windows OpenSSH), kubectl and two user env vars: HCLOUD_TOKEN (Hetzner, project procure-ai) and
    CLOUDFLARE_API_TOKEN (claude-dns: DNS Write + Zone Read on daleabels.com only).
    Everything that is not code stays in %USERPROFILE%\.procure-ai\hosted\ (current user only; DEMO PASSWORDS.txt lists the names):
      procure-hosted_ed25519(.pub)  the VM's SSH key (generated once)
      terraform.tfstate             the Terraform state (local backend, given at init: never in the repo)
      tfplan                        the last plan (applied only after the guard below accepted it)
      host.json                     server ID, type, location, addresses, SSH user (from the Terraform outputs)
      known_hosts                   the VM's host key, recorded on the first connection
      kubeconfig                    context procure-hosted, server https://127.0.0.1:16443 (the tunnel)
    Money guard (before every apply): the plan may hold only the SSH key, network, subnet, firewall (in: tcp 22, 80, 443), one server of an
    approved type (cx43 or cx53, bootstrap/common.ps1 HostedApprovedTypes) in an approved location (fsn1, nbg1, hel1) without backups, and
    exactly the six DNS records (A and AAAA for procure, auth, dashboard; not proxied). The Hetzner API price of the chosen type must not be
    above the approved one. A replacement of the server is refused unless -AllowReplace.
    -WaitForStock: polls GET /v1/server_types until an approved type is available in an approved location (cx43 before cx53, fsn1 before
    nbg1 before hel1), then plans and applies with that pair.
    -Destroy: destroys everything in the state (server, IPv4, DNS records, and the free firewall, network and SSH key too: they cost
    nothing but are recreated in seconds), then checks through both APIs that no procure-ai server and none of the DNS records is left.
    Safe to run again: with nothing to change, Terraform applies nothing and the rest is re-checked.
#>
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    # Approved server type (Dale, 2026-11-07): cx43 (EUR 15.99 net a month) or cx53 (EUR 29.49 net).
    [Parameter(ParameterSetName = 'Create')] [ValidateSet('cx43', 'cx53')] [string] $ServerType = 'cx43',
    # Approved location (network zone eu-central).
    [Parameter(ParameterSetName = 'Create')] [ValidateSet('fsn1', 'nbg1', 'hel1')] [string] $Location = 'fsn1',
    # Wait until an approved type is in stock in an approved location (overrides -ServerType/-Location with the first available pair).
    [Parameter(ParameterSetName = 'Create')] [switch] $WaitForStock,
    # How long -WaitForStock polls (once a minute).
    [Parameter(ParameterSetName = 'Create')] [int] $WaitMinutes = 120,
    # Stop after the plan (and its guard).
    [Parameter(ParameterSetName = 'Create')] [switch] $PlanOnly,
    # Allow a plan that replaces the server (it loses all its data). Only when recreating the VM on purpose.
    [Parameter(ParameterSetName = 'Create')] [switch] $AllowReplace,
    # Destroy the hosted setup (pauses the cost).
    [Parameter(ParameterSetName = 'Destroy', Mandatory)] [switch] $Destroy,
    # Apply (or destroy) without asking (the guard still runs).
    [switch] $AutoApprove
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra\hetzner'

foreach ($tool in 'terraform', 'ssh', 'ssh-keygen', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
}
# The providers read their tokens from the environment; a shell started before a variable was set does not have it yet.
foreach ($name in 'HCLOUD_TOKEN', 'CLOUDFLARE_API_TOKEN') { [Environment]::SetEnvironmentVariable($name, (Get-ApiToken $name)) }

function Invoke-Terraform {
    $out = & terraform "-chdir=$tfDir" @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "terraform $($args -join ' ') failed: $($out -join [Environment]::NewLine)" }
    $out | ForEach-Object { "$_" }
}
function Format-Price($p) { "EUR {0:N2} net / {1:N2} gross a month, plus IPv4 EUR {2:N2} / {3:N2}" -f $p.Net, $p.Gross, $p.Ipv4Net, $p.Ipv4Gross }

# --- 1. The SSH key and the state -----------------------------------------------------------------------------------------------------------
Set-CurrentUserOnlyAcl $HostedDir
if (-not (Test-Path $HostedSshKey)) {
    $out = & ssh-keygen -q -t ed25519 -N '' -C 'procure-hosted admin' -f $HostedSshKey 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed: $out" }
    Set-CurrentUserOnlyAcl $HostedDir
    Write-Host "SSH key generated: $HostedSshKey(.pub)"
}
$fingerprint = ((& ssh-keygen -l -f "$HostedSshKey.pub" 2>&1) -join ' ').Split(' ')[1]
Write-Host "SSH key: $fingerprint"
# Always the hosted state (also in a fresh clone): -reconfigure points this checkout's .terraform at it, never at ./terraform.tfstate.
Invoke-Terraform init -input=false -no-color -reconfigure "-backend-config=path=$HostedStateFile" | Out-Null
# No state file yet (a fresh PC, or the file was lost): Terraform's `state list` exits 1 there; that is an empty state, not an error.
$state = if (Test-Path $HostedStateFile) { @(Invoke-Terraform state list | Where-Object { $_ }) } else { @() }
$hasServer = $state -contains 'hcloud_server.node'
# An existing server keeps its type and location, read from the state (not host.json, which may be missing, and never a default): a
# location change would replace it, a type change is an in-place rescale; the guard refuses both without -AllowReplace.
$existingServer = $null
if ($hasServer) {
    $stateJson = (Invoke-Terraform show -json) -join "`n" | ConvertFrom-Json -Depth 50
    $existingServer = ($stateJson.values.root_module.resources | Where-Object address -eq 'hcloud_server.node').values
    if (-not $existingServer) { throw "The state lists hcloud_server.node but terraform show has no values for it; check $HostedStateFile." }
    if (-not $PSBoundParameters.ContainsKey('ServerType')) { $ServerType = $existingServer.server_type }
    if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = $existingServer.location }
}

function Get-TfVars {
    @('-var', "ssh_public_key_path=$HostedSshKey.pub", '-var', "k3s_version=$HostedK3sVersion",
        '-var', "server_type=$ServerType", '-var', "location=$Location")
}

# --- Destroy ---------------------------------------------------------------------------------------------------------------------------
if ($Destroy) {
    if (-not $state) {
        Write-Host "The state at $HostedStateFile is $(if (Test-Path $HostedStateFile) { 'empty' } else { 'missing' }): Terraform manages nothing to destroy."
    } else {
        Write-Host "Destroying (state $HostedStateFile): $($state -join ', ')"
        if (-not $AutoApprove) {
            $answer = Read-Host 'Destroy the hosted VM (all its data) and its DNS records? (type yes)'
            if ($answer -ne 'yes') { Write-Host 'Not destroyed.'; return }
        }
        Invoke-Terraform destroy -input=false -no-color -auto-approve @(Get-TfVars) | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
        Remove-Item $HostedHostFile, $HostedKubeconfig -ErrorAction SilentlyContinue
        & (Join-Path $PSScriptRoot 'open-tunnel.ps1') -Close | Out-Host
    }
    # Whatever the state said: the APIs must show nothing that bills or still points at an old address.
    $servers = @((Invoke-HetznerApi 'servers?label_selector=app%3Dprocure-ai').servers)
    $allServers = @((Invoke-HetznerApi 'servers').servers)
    $records = Get-HostedDnsRecords
    if ($servers -or $records) {
        throw "Still there after destroy: $($servers.Count) procure-ai server(s) ($(($servers | ForEach-Object { "$($_.id) $($_.name)" }) -join ', ')), $($records.Count) DNS record(s). Check the Hetzner console and Cloudflare."
    }
    Write-Host "Checked through the APIs: no procure-ai server (servers in the project: $($allServers.Count)), no procure/auth/dashboard DNS record."
    return
}

# --- 2. Wait for stock (optional), plan, guard, apply -------------------------------------------------------------------------------------
if ($WaitForStock -and -not $hasServer) {
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $found = $null
    $errors = 0
    $maxErrors = 10
    while (-not $found) {
        try {
            foreach ($type in $HostedApprovedTypes.Keys) {
                $typeInfo = (Invoke-HetznerApi "server_types?name=$type").server_types | Select-Object -First 1
                foreach ($loc in $HostedApprovedLocations) {
                    if (-not $found -and @($typeInfo.locations | Where-Object { $_.name -eq $loc -and $_.available }).Count) { $found = @($type, $loc) }
                }
            }
            $errors = 0
        } catch {
            # A 429 or 5xx must not end a long wait; many in a row mean something is really wrong (token, network): stop.
            $errors++
            Write-Host "$(Get-Date -Format HH:mm) Hetzner API error ($errors of $maxErrors in a row): $($_.Exception.Message)"
            if ($errors -ge $maxErrors) { throw "-WaitForStock stopped after $maxErrors Hetzner API errors in a row." }
        }
        if ($found) { break }
        if ((Get-Date) -gt $deadline) { throw "No approved type ($($HostedApprovedTypes.Keys -join ', ')) in stock in $($HostedApprovedLocations -join ', ') within $WaitMinutes minutes." }
        Write-Host "$(Get-Date -Format HH:mm) no approved type in stock yet; checking again in a minute."
        Start-Sleep -Seconds 60
    }
    $ServerType, $Location = $found
    Write-Host "In stock: $ServerType in $Location."
}

$price = Get-HostedServerPrice $ServerType $Location
$planFile = Join-Path $HostedDir 'tfplan'
Invoke-Terraform plan -input=false -no-color "-out=$planFile" @(Get-TfVars) | Out-Null
$plan = (Invoke-Terraform show -json $planFile) -join "`n" | ConvertFrom-Json -Depth 50

$dnsKeys = foreach ($h in $HostedDnsHosts) { "$h-A"; "$h-AAAA" }
$expected = @('hcloud_firewall.public', 'hcloud_network.private', 'hcloud_network_subnet.private', 'hcloud_server.node', 'hcloud_ssh_key.admin') +
    @($dnsKeys | ForEach-Object { "cloudflare_dns_record.host[""$_""]" })
$problems = [System.Collections.Generic.List[string]]::new()
$changes = @($plan.resource_changes | Where-Object { (@($_.change.actions) -join ',') -ne 'no-op' })
foreach ($rc in $plan.resource_changes) {
    if ($rc.address -notin $expected) { $problems.Add("unexpected resource $($rc.address) ($($rc.change.actions -join '/'))") }
}
$planAddresses = @($plan.resource_changes | ForEach-Object { "$($_.address)" })
foreach ($address in $expected) {
    if ($address -notin $planAddresses) { $problems.Add("missing resource $address") }
}
$server = $plan.resource_changes | Where-Object address -eq 'hcloud_server.node'
if ($server) {
    $after = $server.change.after
    if (-not $HostedApprovedTypes.Contains("$($after.server_type)")) { $problems.Add("server type $($after.server_type) is not approved ($($HostedApprovedTypes.Keys -join ', '))") }
    if ($after.location -notin $HostedApprovedLocations) { $problems.Add("location $($after.location) is not approved ($($HostedApprovedLocations -join ', '))") }
    if ($after.server_type -ne $ServerType -or $after.location -ne $Location) { $problems.Add("plan has $($after.server_type) in $($after.location), asked for $ServerType in $Location") }
    if ($after.backups -eq $true) { $problems.Add('backups are on (they bill 20 % extra)') }
    if ($after.PSObject.Properties['placement_group_id'] -and $after.placement_group_id) { $problems.Add('the server joins a placement group') }
    if ($after.PSObject.Properties['iso'] -and $after.iso) { $problems.Add('the server mounts an ISO') }
    if ('delete' -in $server.change.actions -and -not $AllowReplace) { $problems.Add('the plan deletes or replaces the server (all its data); rerun with -AllowReplace only on purpose') }
    $before = $server.change.before
    if ($before -and $before.server_type -ne $after.server_type -and -not $AllowReplace) {
        $problems.Add("the plan changes the running server from $($before.server_type) to $($after.server_type) (a rescale shuts it down); rerun with -AllowReplace only on purpose")
    }
}
if ($HostedApprovedTypes.Contains($ServerType) -and $price.Net -gt $HostedApprovedTypes[$ServerType]) {
    $problems.Add("Hetzner now asks EUR $($price.Net) net for $ServerType in $Location; approved is EUR $($HostedApprovedTypes[$ServerType]). Ask Dale.")
}
$firewall = $plan.resource_changes | Where-Object address -eq 'hcloud_firewall.public'
if ($firewall -and $firewall.change.after) {
    $rules = @($firewall.change.after.rule | ForEach-Object { "$($_.direction)/$($_.protocol)/$($_.port)" } | Sort-Object)
    if (($rules -join ',') -ne 'in/tcp/22,in/tcp/443,in/tcp/80') { $problems.Add("firewall rules are $($rules -join ', '), expected in/tcp 22, 80, 443 only") }
}
$wantNames = $HostedDnsHosts | ForEach-Object { "$_.$HostedDomain" }
foreach ($rc in @($plan.resource_changes | Where-Object type -eq 'cloudflare_dns_record')) {
    $a = $rc.change.after
    if (-not $a) { continue }
    if ($a.zone_id -ne $HostedCloudflareZoneId -or $a.name -notin $wantNames -or $a.type -notin 'A', 'AAAA' -or $a.proxied -ne $false) {
        $problems.Add("DNS record $($rc.address): $($a.type) $($a.name) in zone $($a.zone_id), proxied=$($a.proxied); expected A/AAAA for $($wantNames -join ', '), not proxied")
    }
}
foreach ($rc in $changes) {
    $extra = if ($rc.type -eq 'cloudflare_dns_record' -and $rc.change.after) { " ($($rc.change.after.type) $($rc.change.after.name), proxied=$($rc.change.after.proxied), ttl $($rc.change.after.ttl))" }
    elseif ($rc.address -eq 'hcloud_server.node' -and $rc.change.after) { " ($($rc.change.after.server_type) in $($rc.change.after.location), $($rc.change.after.image), backups=$($rc.change.after.backups))" }
    Write-Host "plan: $($rc.change.actions -join '/') $($rc.address)$extra"
}
if ($problems.Count -gt 0) { Remove-Item $planFile -ErrorAction SilentlyContinue; throw "Plan rejected (nothing applied):`n  $($problems -join "`n  ")" }
Write-Host "Plan accepted: $($changes.Count) change(s), only the expected resources. $ServerType in $Location costs $(Format-Price $price)$(if (-not $price.Available -and -not $hasServer) { '; NOT in stock right now (try -WaitForStock)' })."
if ($PlanOnly) { Remove-Item $planFile -ErrorAction SilentlyContinue; return }

if ($changes.Count -gt 0) {
    if (-not $AutoApprove) {
        $answer = Read-Host "Apply this plan? $ServerType in $Location bills $(Format-Price $price) while it exists (type yes)"
        if ($answer -ne 'yes') { Write-Host 'Not applied.'; return }
    }
    Invoke-Terraform apply -input=false -no-color $planFile | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
}
Remove-Item $planFile -ErrorAction SilentlyContinue
$serverCreated = $server -and ('create' -in $server.change.actions)

$outputs = (Invoke-Terraform output -json) -join "`n" | ConvertFrom-Json
$hostInfo = [ordered]@{
    serverId  = $outputs.server_id.value
    type      = $outputs.server_type.value
    location  = $outputs.location.value
    ipv4      = $outputs.ipv4_address.value
    ipv6      = $outputs.ipv6_address.value
    privateIp = $outputs.private_ip.value
    user      = $outputs.admin_user.value
    dnsNames  = @($outputs.dns_names.value)
}
$hostInfo | ConvertTo-Json | Set-Content -Path $HostedHostFile
Write-Host "Server $($hostInfo.serverId) ($($hostInfo.type), $($hostInfo.location)): $($hostInfo.ipv4) / $($hostInfo.ipv6), private $($hostInfo.privateIp); DNS $($hostInfo.dnsNames -join ', ')"

# --- 3. First SSH contact, cloud-init --------------------------------------------------------------------------------------------------
# The host key is recorded on the first connection (trust on first use: the server is minutes old and reached at the address Terraform
# just got from the Hetzner API); later connections require the same key (StrictHostKeyChecking=yes in Get-HostedSshArgs). A new server
# may get an address an older one had: its stale entry goes first.
$target = "$($hostInfo.user)@$($hostInfo.ipv4)"
if ($serverCreated -and (Test-Path $HostedKnownHosts)) {
    foreach ($address in $hostInfo.ipv4, ($hostInfo.ipv6 -split '/')[0]) { & ssh-keygen -R $address -f $HostedKnownHosts 2>&1 | Out-Null }
}
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
