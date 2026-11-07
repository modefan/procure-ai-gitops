#Requires -Version 7.4
<#
.SYNOPSIS
    Builds (or checks) the hosted setup with Terraform (infra/hosted): the Contabo VPS Dale bought, reinstalled with Ubuntu, the VM's SSH
    key and cloud-init (k3s); Contabo's firewall; the Cloudflare DNS records procure/auth/dashboard.daleabels.com. Then waits for
    cloud-init, fetches the kubeconfig, opens the SSH tunnel and creates the namespaces. Next: new-secrets.ps1 -Environment hosted,
    install-argocd.ps1 -Environment hosted.
.DESCRIPTION
    Needs terraform, ssh/ssh-keygen (Windows OpenSSH), kubectl and the user env vars CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET, CONTABO_USER,
    CONTABO_PASSWORD (Contabo API) and CLOUDFLARE_API_TOKEN (claude-dns: DNS Write + Zone Read on daleabels.com only).
    Everything that is not code stays in %USERPROFILE%\.procure-ai\hosted\ (current user only; DEMO PASSWORDS.txt lists the names):
      procure-hosted_ed25519(.pub)  the VM's SSH key (generated once)
      terraform.tfstate             the Terraform state (local backend, given at init: never in the repo)
      tfplan                        the plan being applied (deleted afterwards)
      host.json                     instance ID, addresses, node address, SSH user, firewall ID, DNS names (from the Terraform outputs)
      known_hosts                   the VM's host key, recorded on the first connection after each reinstall
      kubeconfig                    context procure-hosted, server https://127.0.0.1:16443 (the tunnel)

    Money guard (before every apply). Terraform only ADOPTS the instance Dale bought (bootstrap/common.ps1 HostedInstanceId, Cloud VPS 8,
    EUR 14.00 a month); it never orders or cancels one. Checked through the Contabo API before the plan: the instance exists, is product
    V155 in region EU and has no cancellation date. The plan may hold only the SSH key secret, the adopted instance (never a create without
    that existing_instance_id, never a delete), the firewall (one active rule: in tcp 22, 80, 443 from anywhere, on this instance) and
    exactly the three DNS records (A for procure, auth, dashboard; not proxied; no AAAA, k3s is IPv4 only). Deleting one of our own DNS
    records is allowed (e.g. the AAAA records of the first version). The check runs in every path that changes something: apply and
    -Destroy. Terraform in infra/hosted is run ONLY through this script (a raw apply skips the check).
    Adopting the instance REINSTALLS it (all data on it is lost), so a plan that adopts it is applied only with -Reinstall. The first run
    on the new VPS needs -Reinstall; later runs change only the firewall and the DNS records.
    -Reinstall on a VM Terraform already manages: forgets it in the state and adopts it again, which reinstalls it with the current image,
      key and cloud-init.yaml (the deliberate way to apply a cloud-init change).
    -Destroy: takes the demo off its names: removes the DNS records, nothing else. The firewall stays (it is free, and the VM keeps running
      k3s), the instance stays managed and is NOT cancelled; it keeps billing until Dale cancels it in the Contabo panel (procure-ai
      docs/hosting.md). Afterwards both APIs are checked: no DNS record left, the firewall still active on the instance, the instance not
      cancelled. A normal run brings the records back.
    The root password Dale received with the VPS stays valid for the Contabo console: the script keeps it in a Contabo password secret
    (procure-hosted-root-password, created once from DEMO PASSWORDS.txt without printing it) that the reinstall uses.
    Safe to run again: with nothing to change, Terraform applies nothing and the rest is re-checked.
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    # Stop after the plan (and its guard).
    [Parameter(ParameterSetName = 'Apply')] [switch] $PlanOnly,
    # Allow (or, when Terraform already manages the VM, force) the reinstall that adopting the instance means. All data on the VM is lost.
    [Parameter(ParameterSetName = 'Apply')] [switch] $Reinstall,
    # Remove the DNS records only (the VM, its firewall and the SSH key stay; nothing is cancelled).
    [Parameter(ParameterSetName = 'Destroy', Mandatory)] [switch] $Destroy,
    # Apply (or destroy) without asking (the guard still runs).
    [switch] $AutoApprove
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tfDir = Join-Path $repoRoot 'infra\hosted'

foreach ($tool in 'terraform', 'ssh', 'ssh-keygen', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
}
# The providers read their credentials from the process environment (never from a file or the command line).
[Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', (Get-ApiToken 'CLOUDFLARE_API_TOKEN'))
foreach ($pair in @(@('CNTB_OAUTH2_CLIENT_ID', 'CONTABO_CLIENT_ID'), @('CNTB_OAUTH2_CLIENT_SECRET', 'CONTABO_CLIENT_SECRET'),
        @('CNTB_OAUTH2_USER', 'CONTABO_USER'), @('CNTB_OAUTH2_PASS', 'CONTABO_PASSWORD'))) {
    [Environment]::SetEnvironmentVariable($pair[0], (Get-ApiToken $pair[1]))
}

function Invoke-Terraform {
    $out = & terraform "-chdir=$tfDir" @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "terraform $($args -join ' ') failed: $($out -join [Environment]::NewLine)" }
    $out | ForEach-Object { "$_" }
}

function Get-Instance {
    # The paid instance as the Contabo API reports it; throws when it is gone.
    $instance = @((Invoke-ContaboApi "compute/instances/$HostedInstanceId").data)[0]
    if (-not $instance) { throw "Contabo has no instance $HostedInstanceId." }
    $instance
}

function Assert-InstanceIsTheBoughtOne($instance) {
    $problems = @()
    if ($instance.productId -ne $HostedProductId) { $problems += "product $($instance.productId), expected $HostedProductId" }
    if ($instance.region -ne 'EU') { $problems += "region $($instance.region), expected EU" }
    if ($instance.cancelDate) { $problems += "it is cancelled for $($instance.cancelDate)" }
    if ($problems) { throw "Instance $HostedInstanceId is not the one Dale bought as expected: $($problems -join '; '). Nothing changed." }
}

# --- 1. The SSH key, the state, the instance -------------------------------------------------------------------------------------------
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
$managed = $state -contains 'contabo_instance.vps'
$instance = Get-Instance
Assert-InstanceIsTheBoughtOne $instance
Write-Host "Instance $HostedInstanceId ($($instance.productId), $($instance.region), $HostedMonthlyPrice a month): $($instance.status), Terraform $(if ($managed) { 'manages it' } else { 'does not manage it yet' })."

# The plan check: only the expected resources, never a new or a cancelled instance (details in the help above). Returns the problems; an
# empty list means the plan may be applied. -DestroyOnly: the plan may only delete our own DNS records.
function Test-Plan($plan, [switch] $DestroyOnly) {
    $dnsKeys = foreach ($h in $HostedDnsHosts) { "$h-A" }
    $expected = @('contabo_secret.ssh', 'contabo_instance.vps', 'contabo_firewall.public') + @($dnsKeys | ForEach-Object { "cloudflare_dns_record.host[""$_""]" })
    $problems = [System.Collections.Generic.List[string]]::new()
    $planAddresses = @($plan.resource_changes | ForEach-Object { "$($_.address)" })
    foreach ($rc in $plan.resource_changes) {
        $actions = (@($rc.change.actions) -join ',')
        $ownDnsDelete = $rc.type -eq 'cloudflare_dns_record' -and $rc.address -like 'cloudflare_dns_record.host*' -and $actions -eq 'delete'
        if ($rc.address -notin $expected -and -not $ownDnsDelete) { $problems.Add("unexpected resource $($rc.address) ($actions)") }
        if ($rc.type -like 'contabo_*' -and $rc.type -notin 'contabo_secret', 'contabo_instance', 'contabo_firewall') { $problems.Add("$($rc.type) may cost money") }
        if ($DestroyOnly -and $actions -notin 'no-op', 'read' -and -not $ownDnsDelete) { $problems.Add("-Destroy may delete only DNS records, not $($rc.address) ($actions)") }
        if ($rc.type -eq 'contabo_firewall' -and 'delete' -in @($rc.change.actions)) { $problems.Add('the plan deletes the firewall of a VM that keeps running k3s') }
    }
    if (-not $DestroyOnly) { foreach ($address in $expected) { if ($address -notin $planAddresses) { $problems.Add("missing resource $address") } } }
    $vps = $plan.resource_changes | Where-Object address -eq 'contabo_instance.vps'
    if ($vps) {
        $actions = @($vps.change.actions)
        if ('delete' -in $actions) { $problems.Add('the plan deletes the instance, which CANCELS the paid VPS: never') }
        if ('create' -in $actions) {
            $after = $vps.change.after
            if ("$($after.existing_instance_id)" -ne $HostedInstanceId) { $problems.Add("the plan creates an instance without existing_instance_id=${HostedInstanceId}: that would ORDER a new VPS") }
            if ($after.PSObject.Properties['add_ons'] -and @($after.add_ons).Count) { $problems.Add('the plan adds add-ons (they cost money)') }
            if (-not $Reinstall) { $problems.Add("the plan adopts instance $HostedInstanceId, which REINSTALLS it (all data lost); rerun with -Reinstall only on purpose") }
        }
    }
    $firewall = $plan.resource_changes | Where-Object address -eq 'contabo_firewall.public'
    if ($firewall -and $firewall.change.after) {
        $a = $firewall.change.after
        $inbound = @($a.rules | ForEach-Object { $_.inbound } | Where-Object { $_ -and $_.action -ne 'drop' })
        $shape = @($inbound | ForEach-Object {
            "$($_.protocol)/$($_.action)/$($_.status)/$((@($_.dest_ports) | Sort-Object) -join ',')/$((@($_.src_cidr | ForEach-Object { @($_.ipv4) + @($_.ipv6) }) | Sort-Object) -join ',')"
        })
        if ($a.status -ne 'active' -or ($shape -join ';') -notin 'tcp/accept/active/22,443,80/0.0.0.0/0,::/0', 'tcp/accept/active/22,443,80/::/0,0.0.0.0/0') {
            $problems.Add("firewall is $($a.status) with rules '$($shape -join '; ')', expected one active rule in tcp 22, 80, 443 from 0.0.0.0/0 and ::/0")
        }
        if ("$(@($a.instance_ids) -join ',')" -ne $HostedInstanceId) { $problems.Add("firewall holds instances '$(@($a.instance_ids) -join ',')', expected $HostedInstanceId") }
    }
    $wantNames = $HostedDnsHosts | ForEach-Object { "$_.$HostedDomain" }
    foreach ($rc in @($plan.resource_changes | Where-Object type -eq 'cloudflare_dns_record')) {
        $a = $rc.change.after
        if (-not $a) { continue }
        if ($a.zone_id -ne $HostedCloudflareZoneId -or $a.name -notin $wantNames -or $a.type -ne 'A' -or $a.proxied -ne $false) {
            $problems.Add("DNS record $($rc.address): $($a.type) $($a.name) in zone $($a.zone_id), proxied=$($a.proxied); expected A for $($wantNames -join ', '), not proxied")
        }
    }
    $problems
}

function Show-Plan($plan) {
    foreach ($rc in @($plan.resource_changes | Where-Object { (@($_.change.actions) -join ',') -notin 'no-op', 'read' })) {
        $extra = if ($rc.type -eq 'cloudflare_dns_record' -and $rc.change.after) { " ($($rc.change.after.type) $($rc.change.after.name), proxied=$($rc.change.after.proxied), ttl $($rc.change.after.ttl))" }
        elseif ($rc.type -eq 'cloudflare_dns_record' -and $rc.change.before) { " ($($rc.change.before.type) $($rc.change.before.name))" }
        elseif ($rc.address -eq 'contabo_instance.vps' -and $rc.change.after) { " (adopts existing instance $($rc.change.after.existing_instance_id), image $($rc.change.after.image_id): REINSTALL)" }
        Write-Host "plan: $($rc.change.actions -join '/') $($rc.address)$extra"
    }
}

# --- Destroy: the DNS records only (never the firewall of a running VM, never the instance) ---------------------------------------------
if ($Destroy) {
    $records = @($state | Where-Object { $_ -like 'cloudflare_dns_record.host*' })
    if ($records) {
        $tfVars = @('-var', "ssh_public_key_path=$HostedSshKey.pub", '-var', "k3s_version=$HostedK3sVersion")
        $planFile = Join-Path $HostedDir 'tfplan'
        $targets = @($records | ForEach-Object { "-target=$_" })
        Invoke-Terraform plan -destroy -input=false -no-color "-out=$planFile" @targets @tfVars | Out-Null
        $plan = (Invoke-Terraform show -json $planFile) -join "`n" | ConvertFrom-Json -Depth 50
        Show-Plan $plan
        $problems = @(Test-Plan $plan -DestroyOnly)
        if ($problems) { Remove-Item $planFile -ErrorAction SilentlyContinue; throw "Destroy plan rejected (nothing changed):`n  $($problems -join "`n  ")" }
        if (-not $AutoApprove) {
            $answer = Read-Host 'Remove the DNS records (the VM, its firewall and the SSH key stay; nothing is cancelled)? (type yes)'
            if ($answer -ne 'yes') { Remove-Item $planFile -ErrorAction SilentlyContinue; Write-Host 'Nothing changed.'; return }
        }
        $out = & terraform "-chdir=$tfDir" apply -input=false -no-color $planFile 2>&1
        $exit = $LASTEXITCODE
        Remove-Item $planFile -ErrorAction SilentlyContinue
        if ($exit -ne 0) { throw "terraform apply (destroy plan) failed: $($out -join [Environment]::NewLine)" }
        $out | Select-Object -Last 1 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host 'The state holds no DNS record: nothing to remove.'
    }
    $left = Get-HostedDnsRecords
    $firewalls = @((Invoke-ContaboApi 'firewalls?size=100').data | Where-Object { $_.status -eq 'active' -and @($_.instances | Where-Object { "$($_.instanceId)" -eq $HostedInstanceId }).Count })
    $after = Get-Instance
    if ($left -or $firewalls.Count -ne 1 -or $after.cancelDate) {
        throw "After -Destroy: $($left.Count) DNS record(s) left, $($firewalls.Count) active firewall(s) on the instance, cancel date '$($after.cancelDate)'. Check Cloudflare and the Contabo panel."
    }
    Write-Host "Checked through the APIs: no procure/auth/dashboard DNS record; firewall $($firewalls[0].name) still active on the instance; instance $HostedInstanceId $($after.status) and NOT cancelled (it bills $HostedMonthlyPrice a month until Dale cancels it in the Contabo panel). A normal run of this script brings the records back."
    return
}

# --- 2. Root password secret, plan, guard, apply ------------------------------------------------------------------------------------------
function Get-RootPasswordSecretId {
    # The Contabo password secret holding the root password Dale received (so a reinstall keeps it valid for the console). Created once
    # from DEMO PASSWORDS.txt: the value goes from the file into the API request, never to the console or a file.
    $existing = @((Invoke-ContaboApi "secrets?name=$([uri]::EscapeDataString($HostedRootPasswordSecretName))&type=password").data |
        Where-Object name -eq $HostedRootPasswordSecretName)
    if ($existing) { return [int64] $existing[0].secretId }
    $file = Join-Path $env:USERPROFILE 'Desktop\DEMO PASSWORDS.txt'
    $inSection = $false; $value = $null
    foreach ($line in [IO.File]::ReadLines($file)) {
        if ($line -match '^===') { $inSection = $line -match '^=== Contabo ===' ; continue }
        if ($inSection -and $line -match '^\s*VPS root password[^:]*:\s*(\S.*?)\s*$') { $value = $Matches[1]; break }
    }
    if (-not $value) { throw "No 'VPS root password' line in the Contabo section of $file; cannot keep the root password across the reinstall." }
    $created = Invoke-ContaboApi -Path 'secrets' -Method Post -Body @{ name = $HostedRootPasswordSecretName; value = $value; type = 'password' }
    Remove-Variable value
    Write-Host "Contabo password secret $HostedRootPasswordSecretName created (keeps Dale's root password for the console)."
    [int64] @($created.data)[0].secretId
}

if ($Reinstall -and $managed) {
    if (-not $AutoApprove) {
        $answer = Read-Host "Reinstall instance $HostedInstanceId (ALL data on the VM is lost; it then runs cloud-init.yaml from scratch)? (type yes)"
        if ($answer -ne 'yes') { Write-Host 'Nothing changed.'; return }
    }
    # Forgotten in the state, the instance is adopted again by the apply below, and adopting means reinstalling.
    Invoke-Terraform state rm contabo_instance.vps | ForEach-Object { Write-Host $_ }
    $managed = $false
}

$rootSecretId = Get-RootPasswordSecretId
$tfVars = @('-var', "ssh_public_key_path=$HostedSshKey.pub", '-var', "k3s_version=$HostedK3sVersion", '-var', "root_password_secret_id=$rootSecretId")
$planFile = Join-Path $HostedDir 'tfplan'
Invoke-Terraform plan -input=false -no-color "-out=$planFile" @tfVars | Out-Null
$plan = (Invoke-Terraform show -json $planFile) -join "`n" | ConvertFrom-Json -Depth 50

$problems = @(Test-Plan $plan)
$adopts = [bool] (@($plan.resource_changes | Where-Object { $_.address -eq 'contabo_instance.vps' -and 'create' -in @($_.change.actions) }).Count)
$changes = @($plan.resource_changes | Where-Object { (@($_.change.actions) -join ',') -notin 'no-op', 'read' })
Show-Plan $plan
if ($problems) { Remove-Item $planFile -ErrorAction SilentlyContinue; throw "Plan rejected (nothing applied):`n  $($problems -join "`n  ")" }
Write-Host "Plan accepted: $($changes.Count) change(s), only the expected resources; no new paid resource (the VPS is the one Dale pays $HostedMonthlyPrice a month for)$(if ($adopts) { '; the VM will be REINSTALLED' })."
if ($PlanOnly) { Remove-Item $planFile -ErrorAction SilentlyContinue; return }

if ($changes.Count -gt 0) {
    if (-not $AutoApprove) {
        $answer = Read-Host "Apply this plan?$(if ($adopts) { ' The VM is reinstalled (all data lost).' }) (type yes)"
        if ($answer -ne 'yes') { Remove-Item $planFile -ErrorAction SilentlyContinue; Write-Host 'Not applied.'; return }
    }
    $applyOut = & terraform "-chdir=$tfDir" apply -input=false -no-color $planFile 2>&1
    $applyExit = $LASTEXITCODE
    Remove-Item $planFile -ErrorAction SilentlyContinue
    if ($applyExit -ne 0) { throw "terraform apply failed: $($applyOut -join [Environment]::NewLine)" }
    $applyOut | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
    if ($adopts) {
        # Provider 0.1.44 drops the reinstall call's error (resourceInstanceUpdate ignores it), so ask the API: a failed reinstall shows as
        # status error / an errorMessage, or the instance never gets the new SSH key.
        $keyId = [int64] ((Invoke-Terraform output -raw ssh_key_secret_id) -join '')
        $deadline = (Get-Date).AddMinutes(15)
        while ($true) {
            $now = Get-Instance
            if ($now.status -eq 'error' -or $now.errorMessage) { throw "The reinstall of instance $HostedInstanceId failed (Contabo API: status $($now.status), '$($now.errorMessage)')." }
            if ($now.status -eq 'running' -and @($now.sshKeys) -contains $keyId) { Write-Host "Reinstall accepted (Contabo API: running, SSH key $keyId on the instance)."; break }
            if ((Get-Date) -gt $deadline) { throw "The reinstall of instance $HostedInstanceId did not finish within 15 minutes (Contabo API: status $($now.status), SSH keys $(@($now.sshKeys) -join ','))." }
            Start-Sleep -Seconds 20
        }
    }
}
Remove-Item $planFile -ErrorAction SilentlyContinue

$outputs = (Invoke-Terraform output -json) -join "`n" | ConvertFrom-Json
$hostInfo = [ordered]@{
    instanceId = "$($outputs.instance_id.value)"
    product    = $outputs.product_id.value
    region     = (Get-Instance).region
    ipv4       = $outputs.ipv4_address.value
    ipv6       = $outputs.ipv6_address.value
    nodeIp     = $outputs.node_ip.value
    user       = $outputs.admin_user.value
    firewallId = "$($outputs.firewall_id.value)"
    dnsNames   = @($outputs.dns_names.value)
}
$hostInfo | ConvertTo-Json | Set-Content -Path $HostedHostFile
Write-Host "Instance $($hostInfo.instanceId) ($($hostInfo.product), $($hostInfo.region)): $($hostInfo.ipv4) / $($hostInfo.ipv6), node $($hostInfo.nodeIp); firewall $($hostInfo.firewallId); DNS $($hostInfo.dnsNames -join ', ')"

# --- 3. First SSH contact, cloud-init --------------------------------------------------------------------------------------------------
# The host key is recorded on the first connection after a reinstall (trust on first use: the VM is minutes old and reached at the
# address the Contabo API reports); later connections require the same key (StrictHostKeyChecking=yes in Get-HostedSshArgs). A reinstall
# makes new host keys: the old entries go first.
$target = "$($hostInfo.user)@$($hostInfo.ipv4)"
if ($adopts -and (Test-Path $HostedKnownHosts)) {
    foreach ($address in $hostInfo.ipv4, $hostInfo.ipv6) { & ssh-keygen -R $address -f $HostedKnownHosts 2>&1 | Out-Null }
}
$known = (Test-Path $HostedKnownHosts) -and ((& ssh-keygen -F $hostInfo.ipv4 -f $HostedKnownHosts 2>$null) -join '') -ne ''
$deadline = (Get-Date).AddMinutes(20)
while ($true) {
    $firstArgs = @(Get-HostedSshArgs) | ForEach-Object { if ($_ -eq 'StrictHostKeyChecking=yes' -and -not $known) { 'StrictHostKeyChecking=accept-new' } else { $_ } }
    $out = & ssh @firstArgs $target 'true' 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw "SSH to $target did not work within 20 minutes: $($out -join ' ')" }
    Start-Sleep -Seconds 15
}
Write-Host "SSH works ($target); host key in $HostedKnownHosts."
# Contabo merges its own cloud-config into the user data: a bootcmd that edits sshd_config and runs `pkill -HUP sshd`, which exits 1 on
# Ubuntu 26.04 (no process is called sshd there), so cloud-init reports "error" on every boot although everything of ours ran. Accept
# that one known failure, nothing else (our 00- sshd drop-in wins over Contabo's PermitRootLogin yes; Test-HostBaseline checks it).
# Our cloud-init.yaml has no bootcmd of its own (checked here), and the merged bootcmd list on the VM must be exactly Contabo's three
# commands: cloud-init's error text cannot tell the commands apart, so the list itself is compared (it holds no secret).
if ((Get-Content -Raw (Join-Path $tfDir 'cloud-init.yaml')) -match '(?m)^bootcmd:') { throw 'infra/hosted/cloud-init.yaml must not have a bootcmd (the cloud-init check below could no longer tell its failures from Contabo''s).' }
$contaboBootcmd = @(
    "sed 's/#PermitRootLogin .*/PermitRootLogin yes/' -i /etc/ssh/sshd_config",
    'grep PermitRootLogin /etc/ssh/sshd_config || echo PermitRootLogin yes >> /etc/ssh/sshd_config',
    'pkill -HUP sshd')
$status = @(Invoke-HostedSsh -Command 'cloud-init status --wait >/dev/null 2>&1; cloud-init status --format json' -AllowFailure)
$ci = ($status -join "`n") | ConvertFrom-Json
$errors = @($ci.errors | ForEach-Object { "$_" })
$bootcmd = @()
if ($errors) {
    $bootcmdJson = Invoke-HostedSsh -Command 'sudo python3 -c "import json,yaml; print(json.dumps((yaml.safe_load(open(''/var/lib/cloud/instance/cloud-config.txt'')) or {}).get(''bootcmd'') or []))"'
    $bootcmd = @(($bootcmdJson -join '') | ConvertFrom-Json | ForEach-Object { "$_" })
}
$onlyContaboBootcmd = $errors.Count -gt 0 -and @($errors | Where-Object { $_ -notmatch "^\('bootcmd'," }).Count -eq 0 -and
    ($bootcmd -join "`n") -eq ($contaboBootcmd -join "`n")
Write-Host "cloud-init: $($ci.status)$(if ($errors) { "; errors: $($errors.Count) ($(if ($onlyContaboBootcmd) { 'only Contabo''s own bootcmd' } else { 'see the VM' }))" })"
if (-not ($ci.status -eq 'done' -or ($ci.status -eq 'error' -and $onlyContaboBootcmd))) {
    throw 'cloud-init did not finish cleanly (sudo cloud-init status --long; sudo cat /var/log/cloud-init-output.log on the VM).'
}
$k3s = Invoke-HostedSsh -Command 'systemctl is-active k3s' -AllowFailure
if ("$k3s".Trim() -ne 'active') { throw "k3s is not active on the VM ($k3s); see sudo journalctl -u k3s." }

# --- 4. kubeconfig (through the tunnel) -----------------------------------------------------------------------------------------------
$raw = & ssh @(Get-HostedSshArgs) $target 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Could not read /etc/rancher/k3s/k3s.yaml on the VM (is k3s running? sudo systemctl status k3s).' }
$kubeconfig = ($raw -join "`n") -replace '(?m)^(\s*server:\s*)https://\S+$', "`${1}https://127.0.0.1:$HostedTunnelPort" `
    -replace '(?m)^(\s*(?:-\s+)?(?:name|cluster|user|current-context):\s*)default\s*$', "`${1}$HostedKubeContext"
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
