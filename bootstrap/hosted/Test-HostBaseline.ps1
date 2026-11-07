#Requires -Version 7.4
<#
.SYNOPSIS
    Checks the hosted VM's baseline (plan 08 Task 11, ruling 10) from Dale's PC: SSH, upgrades, k3s, the API's exposure, the firewall.
.DESCRIPTION
    Over SSH (the VM's own key, bootstrap/hosted/):
      - sshd's effective settings: no root login, no password or keyboard-interactive login, only public keys, only the admin user;
      - fail2ban guards sshd and its filter reads the journal of ssh.service including sshd-session (OpenSSH >= 9.8);
      - unattended security upgrades on (APT::Periodic::Unattended-Upgrade 1, service enabled);
      - k3s runs the pinned release (bootstrap/common.ps1 HostedK3sVersion) and the node is Ready;
      - the kubelet's live configuration: shutdownGracePeriod 60s, shutdownGracePeriodCriticalPods 20s; logind waits long enough;
      - the API (6443), the kubelet (10250) and kube-proxy's health port (10256) listen only on the node address (dummy interface) or loopback,
        never on a public interface or a wildcard;
      - WARN (not a failure) when a kernel or library update waits for a reboot (/var/run/reboot-required).
    From the PC, against the public IPv4 (and IPv6 when the PC has a route); before host.json exists, the addresses come from the Contabo
    API, so the outside checks also run against a VM that is not set up yet:
      - root and password logins are refused (the server offers only publickey);
      - 22, 80 and 443 answer; 6443 and the other Kubernetes ports (6444, 10250, 10256, 2379, 2380, 8472/udp is not checked) do not.
    Through the Contabo API: the instance is the one Dale bought (bootstrap/common.ps1: ID, product V155, EU, not cancelled), and exactly
    one active firewall holds it, with exactly one active rule: in tcp 22, 80, 443 from anywhere (IPv4 and IPv6). WARN when Contabo's VNC
    console is enabled (the API cannot turn it off; Dale can in the panel). Through the Cloudflare API: exactly A and AAAA for procure, auth and dashboard
    .daleabels.com, pointing at the server's IPv4 and IPv6, not proxied.
    Prints PASS/FAIL per check and exits 1 when any check fails. Prints no secret.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\common.ps1')
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check([string] $name, [scriptblock] $check) {
    try {
        $detail = & $check
        $results.Add([pscustomobject]@{ Result = 'PASS'; Check = $name; Detail = "$detail" })
    } catch {
        $results.Add([pscustomobject]@{ Result = 'FAIL'; Check = $name; Detail = $_.Exception.Message })
    }
}

function Test-Tcp([string] $address, [int] $port, [int] $timeoutMs = 3000) {
    $family = if ($address.Contains(':')) { [System.Net.Sockets.AddressFamily]::InterNetworkV6 } else { [System.Net.Sockets.AddressFamily]::InterNetwork }
    $client = [System.Net.Sockets.TcpClient]::new($family)
    try { $client.ConnectAsync($address, $port).Wait($timeoutMs) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

$hostInfo = $null
Add-Check 'host.json and SSH key exist (VM created by new-hosted-cluster.ps1)' {
    if (-not (Test-Path $HostedSshKey)) { throw "no SSH key at $HostedSshKey" }
    $script:hostInfo = Get-HostedHost
    "instance $($hostInfo.instanceId) at $($hostInfo.ipv4)"
}
# The public addresses for the outside checks: host.json, or (not set up yet) what the Contabo API reports for the bought instance.
$publicAddresses = $null
try {
    if ($hostInfo) { $publicAddresses = @($hostInfo.ipv4, $hostInfo.ipv6) }
    else {
        $ipConfig = @((Invoke-ContaboApi "compute/instances/$HostedInstanceId").data)[0].ipConfig
        $publicAddresses = @($ipConfig.v4.ip, ([System.Net.IPAddress]::Parse($ipConfig.v6.ip)).ToString())
    }
} catch { }
function Get-Ssh([string] $command) {
    if (-not $script:hostInfo) { throw 'no VM (host.json missing)' }
    Invoke-HostedSsh -Command $command
}

Add-Check 'sshd: no root login, no password or keyboard-interactive login, public keys only, admin user only' {
    $settings = @{}
    foreach ($line in Get-Ssh 'sudo sshd -T') { $k, $v = "$line" -split ' ', 2; $settings[$k] = $v }
    $want = [ordered]@{ permitrootlogin = 'no'; passwordauthentication = 'no'; kbdinteractiveauthentication = 'no'; pubkeyauthentication = 'yes'
        authenticationmethods = 'publickey'; allowusers = $hostInfo.user; permitemptypasswords = 'no'; x11forwarding = 'no'; allowagentforwarding = 'no' }
    $wrong = @($want.Keys | Where-Object { $settings[$_] -ne $want[$_] } | ForEach-Object { "$_=$($settings[$_]) (want $($want[$_]))" })
    if ($wrong) { throw ($wrong -join '; ') }
    ($want.Keys | ForEach-Object { "$_ $($want[$_])" }) -join ', '
}

Add-Check 'from the PC: root and password logins refused (server offers publickey only)' {
    if (-not $publicAddresses) { throw 'no address (host.json missing and the Contabo API did not answer)' }
    $user = if ($hostInfo) { $hostInfo.user } else { 'procure' }
    $ip = $publicAddresses[0]
    # Only refusals are tested here, so the server's host key does not matter (and before the first setup none is recorded): no known_hosts
    # is read or written. Every connection that matters (Invoke-HostedSsh) checks the key strictly.
    $common = @('-o', 'UserKnownHostsFile=NUL', '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')
    # Root with the right key: refused (AllowUsers and PermitRootLogin).
    $root = & ssh @common -i $HostedSshKey -o IdentitiesOnly=yes "root@$ip" true 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'root logged in with the admin key' }
    # No key at all: the server must list only publickey as a method (no password, no keyboard-interactive).
    $nokey = & ssh @common -o PubkeyAuthentication=no -o 'PreferredAuthentications=password,keyboard-interactive' "$user@$ip" true 2>&1
    $denied = ($nokey | ForEach-Object { "$_" }) -match 'Permission denied \(([^)]*)\)'
    if ($LASTEXITCODE -eq 0 -or -not $denied) { throw "unexpected answer without a key: $($nokey -join ' ')" }
    $methods = ([regex]::Match(($nokey -join ' '), 'Permission denied \(([^)]*)\)')).Groups[1].Value
    if ($methods -ne 'publickey') { throw "server offers: $methods" }
    "root refused; methods offered: $methods"
}

Add-Check 'fail2ban guards sshd (journal of ssh.service, sshd-session lines)' {
    $out = Get-Ssh 'systemctl is-active fail2ban && sudo fail2ban-client status sshd | head -1 && sudo fail2ban-client get sshd journalmatch'
    if (-not ($out -contains 'active') -or -not ($out -match 'sshd')) { throw ($out -join ' ') }
    if (-not ($out -match '_SYSTEMD_UNIT=ssh\.service')) { throw "journalmatch does not read ssh.service: $($out -join ' ')" }
    $failed = (Get-Ssh 'sudo fail2ban-client status sshd' | Where-Object { $_ -match 'Total failed' }) -join ' '
    "fail2ban active, jail sshd on ssh.service; $($failed.Trim())"
}

Add-Check 'unattended security upgrades on' {
    $periodic = Get-Ssh 'apt-config dump APT::Periodic::Unattended-Upgrade APT::Periodic::Update-Package-Lists; systemctl is-enabled unattended-upgrades'
    if (-not ($periodic -match 'APT::Periodic::Unattended-Upgrade "1"') -or -not ($periodic -match 'APT::Periodic::Update-Package-Lists "1"') -or -not ($periodic -contains 'enabled')) {
        throw ($periodic -join ' ')
    }
    'Unattended-Upgrade 1, Update-Package-Lists 1, service enabled'
}

Add-Check "k3s runs the pinned release ($HostedK3sVersion), node Ready" {
    $version = (Get-Ssh 'k3s --version | head -1') -join ' '
    if ($version -notmatch [regex]::Escape($HostedK3sVersion)) { throw "k3s: $version" }
    $ready = Get-Ssh "sudo k3s kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type==""Ready"")].status}'"
    if ("$ready" -ne 'True') { throw "node Ready=$ready" }
    "$version; Ready"
}

Add-Check 'kubelet: shutdownGracePeriod 60s, shutdownGracePeriodCriticalPods 20s (live config); logind InhibitDelayMaxSec >= 60 s' {
    $configz = (Get-Ssh 'sudo k3s kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz"') -join '' | ConvertFrom-Json
    $kc = $configz.kubeletconfig
    $seconds = { param($d) if ($d -match '^(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$') { [double]("0$($Matches[1])") * 60 + [double]("0$($Matches[2])") } else { -1 } }
    $grace = & $seconds $kc.shutdownGracePeriod; $critical = & $seconds $kc.shutdownGracePeriodCriticalPods
    if ($grace -ne 60 -or $critical -ne 20) { throw "shutdownGracePeriod=$($kc.shutdownGracePeriod), shutdownGracePeriodCriticalPods=$($kc.shutdownGracePeriodCriticalPods)" }
    $inhibit = (Get-Ssh 'busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec') -join ''
    $usec = [int64] ($inhibit -replace '^t\s+', '')
    if ($usec -lt 60000000) { throw "logind InhibitDelayMaxUSec=$usec" }
    "shutdownGracePeriod $($kc.shutdownGracePeriod), critical $($kc.shutdownGracePeriodCriticalPods), logind $([int]($usec / 1e6)) s"
}

foreach ($port in 6443, 10250, 10256) {
    Add-Check "port $port listens only on the node address, not on a public interface" {
        $listeners = @(Get-Ssh "ss -Hltn 'sport = :$port' | awk '{print `$4}'" | Where-Object { $_ })
        if (-not $listeners) { throw "nothing listens on $port" }
        $bad = @($listeners | Where-Object { $_ -notin @("$($hostInfo.nodeIp):$port", "127.0.0.1:$port", "[::1]:$port") })
        if ($bad) { throw "$port listens on $($bad -join ', ')" }
        "listens on $($listeners -join ', ')"
    }
}

# A warning only: unattended upgrades install kernel fixes, but the VM reboots only when Dale (or Claude) decides (docs/hosting.md).
if ($hostInfo) {
    try {
        $pending = Get-Ssh 'if [ -f /var/run/reboot-required ]; then echo yes; cat /var/run/reboot-required.pkgs 2>/dev/null | head -5; else echo no; fi'
        if ($pending[0] -eq 'yes') {
            $results.Add([pscustomobject]@{ Result = 'WARN'; Check = 'reboot required (updates installed, not active until a reboot)'; Detail = ($pending | Select-Object -Skip 1) -join ', ' })
        }
    } catch { }
}

$addresses = @()
if ($publicAddresses) {
    $addresses += $publicAddresses[0]
    # The PC may have no IPv6 route; check IPv6 only when it does.
    # Only with working IPv6 on the PC (a route alone is not enough): a connection to Cloudflare's resolver over IPv6 must succeed.
    $ipv6 = ($publicAddresses[1] -split '/')[0]
    if ($ipv6 -and (Test-Tcp '2606:4700:4700::1111' 443)) { $addresses += $ipv6 }
    elseif ($ipv6) {
        $results.Add([pscustomobject]@{ Result = 'WARN'; Check = "from the PC: $ipv6 not checked"; Detail = 'this PC has no working IPv6; the firewall rule covers ::/0 the same way (checked through the Contabo API)' })
    }
}
foreach ($address in $addresses) {
    Add-Check "from the PC: $address answers on 22, 80, 443 only (6443, 6444, 10250, 10256, 2379, 2380, 8080 closed)" {
        $open = @(22, 80, 443) | Where-Object { Test-Tcp $address $_ }
        $closed = @(6443, 6444, 10250, 10256, 2379, 2380, 8080) | Where-Object { Test-Tcp $address $_ }
        $problems = @()
        if (@($open).Count -ne 3) { $problems += "open of 22/80/443: $($open -join ', ')" }
        if ($closed) { $problems += "should be closed but answer: $($closed -join ', ')" }
        if ($problems) { throw ($problems -join '; ') }
        '22, 80, 443 answer; the rest do not'
    }
}
if (-not $addresses) { Add-Check 'from the PC: public address answers on 22, 80, 443 only' { throw 'no address (host.json missing and the Contabo API did not answer)' } }

Add-Check 'Contabo API: the bought instance (V155, EU, not cancelled), one active firewall with exactly in tcp 22, 80, 443' {
    $instance = @((Invoke-ContaboApi "compute/instances/$HostedInstanceId").data)[0]
    if ($hostInfo -and $hostInfo.instanceId -ne $HostedInstanceId) { throw "host.json names instance $($hostInfo.instanceId), approved is $HostedInstanceId" }
    if ($instance.productId -ne $HostedProductId -or $instance.region -ne 'EU' -or $instance.cancelDate) {
        throw "instance $HostedInstanceId is $($instance.productId) in $($instance.region), cancel date '$($instance.cancelDate)'"
    }
    $firewalls = @((Invoke-ContaboApi 'firewalls?size=100').data | Where-Object { @($_.instances | Where-Object { "$($_.instanceId)" -eq $HostedInstanceId }).Count })
    if ($firewalls.Count -ne 1) { throw "firewalls holding the instance: $($firewalls.Count)" }
    $fw = $firewalls[0]
    if ($fw.status -ne 'active') { throw "firewall $($fw.name) is $($fw.status)" }
    $active = @($fw.rules.inbound | Where-Object { $_.status -eq 'active' })
    $rules = @($active | Where-Object { $_.action -eq 'accept' } | ForEach-Object {
        "$($_.protocol)/$((@($_.destPorts) | Sort-Object) -join ',')/$((@($_.srcCidr.ipv4) + @($_.srcCidr.ipv6) | Sort-Object) -join ',')" })
    if (($rules -join ';') -notin 'tcp/22,443,80/0.0.0.0/0,::/0', 'tcp/22,443,80/::/0,0.0.0.0/0') { throw "active accept rules: $($rules -join '; ')" }
    # Contabo's own last rule drops everything else (it is what makes the accept rule an allow-list).
    $drop = @($active | Where-Object { $_.action -eq 'drop' -and -not $_.protocol -and -not @($_.destPorts).Count -and -not (@($_.srcCidr.ipv4) + @($_.srcCidr.ipv6) | Where-Object { $_ }) })
    if ($drop.Count -ne 1) { throw "no active 'drop all' rule after the accept rule" }
    $rules += 'drop all'
    $vnc = @((Invoke-ContaboApi "compute/instances/$HostedInstanceId/vnc").data)[0]
    if ($vnc.enabled) {
        $results.Add([pscustomobject]@{ Result = 'WARN'; Check = 'Contabo VNC console is enabled'; Detail = 'the API cannot turn it off; Dale can in the Contabo panel (it needs the root password, which SSH does not accept)' })
    }
    "instance $HostedInstanceId $($instance.productId) $($instance.region) $($instance.status); firewall $($fw.name): $($rules -join '; ')"
}

Add-Check 'Cloudflare API: A and AAAA for procure, auth, dashboard point at the server, not proxied' {
    if (-not $hostInfo) { throw 'no VM (host.json missing)' }
    $records = Get-HostedDnsRecords
    $ipv6 = ($hostInfo.ipv6 -split '/')[0]
    $problems = @()
    foreach ($h in $HostedDnsHosts) {
        foreach ($t in @(@('A', $hostInfo.ipv4), @('AAAA', $ipv6))) {
            $r = @($records | Where-Object { $_.name -eq "$h.$HostedDomain" -and $_.type -eq $t[0] })
            if ($r.Count -ne 1) { $problems += "$($t[0]) $h.$($HostedDomain): $($r.Count) records"; continue }
            if ($r[0].content -ne $t[1]) { $problems += "$($t[0]) $h.$($HostedDomain) -> $($r[0].content), server is $($t[1])" }
            if ($r[0].proxied) { $problems += "$($t[0]) $h.$($HostedDomain) is proxied" }
        }
    }
    if ($problems) { throw ($problems -join '; ') }
    "$($records.Count) records, all to $($hostInfo.ipv4) / $ipv6, DNS only"
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "$($results.Count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
