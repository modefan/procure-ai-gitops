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
      - every TCP and UDP listener on the VM is on loopback or in the allowlist (22 on any address; 6443, 10250, 10256 on the node
        address); on IPv6 only SSH listens, and nothing answers on [v6]:80/443 (k3s is IPv4 only, so there are no AAAA records);
      - flannel uses host-gw (no VXLAN socket on UDP 8472);
      - the host firewall (nftables table inet procure_host) is loaded: on eth0 only replies, 22, 80, 443 (and the ICMP IPv6 needs) come
        in, and only 80/443 are forwarded to pods;
      - the sudo group holds only the admin user (Contabo's merged config also creates the image's `ubuntu` user; cloud-init removes it);
      - WARN (not a failure) when a kernel or library update waits for a reboot (/var/run/reboot-required);
      - k3s runs without ServiceLB (disable: servicelb in /etc/rancher/k3s/config.yaml) and no Service is of type LoadBalancer;
      - Traefik (the public edge) has a memory limit (traefik-config.yaml);
      - the Let's Encrypt certificate ingress-tls/procure-public is Ready, from letsencrypt-production, with more than 21 days left
        (renewal is due at 30; fewer than 21 means renewal has been failing for 9 days);
      - the GHCR pull token (bootstrap/common.ps1 GhcrPullTokenExpires): WARN within 21 days of its expiry, FAIL after it;
      - the PC's hosted kubeconfig: its admin client certificate has more than 30 days left.
    From the PC, against the public IPv4 (and IPv6 when the PC has a route); before host.json exists, the addresses come from the Contabo
    API, so the outside checks also run against a VM that is not set up yet:
      - root and password logins are refused (the server offers only publickey);
      - IPv4: 22, 80 and 443 answer; 6443 and the other Kubernetes ports (6444, 10250, 10256, 2379, 2380, 8080) do not (UDP is covered
        by the listener check on the VM); IPv6 (only from a PC with working IPv6): only 22.
    Through the Contabo API: the instance is the one Dale bought (bootstrap/common.ps1: ID, product V155, EU, not cancelled), and exactly
    one active firewall holds it, with exactly one active rule: in tcp 22, 80, 443 from anywhere (IPv4 and IPv6). WARN when Contabo's VNC
    console is enabled (the API cannot turn it off; Dale can in the panel). Through the Cloudflare API: exactly one A record each for procure, auth and dashboard
    .daleabels.com, pointing at the server's IPv4, not proxied, and no AAAA record for them.
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
    # Only refusals are tested here, so the server's host key does not matter (and before the first setup none is recorded): the real
    # known_hosts is neither read nor written. Every connection that matters (Invoke-HostedSsh) checks the key strictly. A throwaway file,
    # not NUL: Windows OpenSSH wrote "NUL" as a file into the current folder (found in the plan 08 fix wave).
    $throwawayKnownHosts = New-TemporaryFile
    try {
        $common = @('-o', "UserKnownHostsFile=$($throwawayKnownHosts.FullName)", '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')
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
    } finally {
        Remove-Item -LiteralPath $throwawayKnownHosts.FullName -ErrorAction SilentlyContinue
    }
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

Add-Check 'every TCP/UDP listener is on loopback or allowed (22 anywhere; 6443, 10250, 10256 on the node address); IPv6: only SSH' {
    $lines = @(Get-Ssh "ss -Hlntu | awk '{print `$1, `$5}'" | Where-Object { $_ })
    $node = $hostInfo.nodeIp
    # Plan 08 Task 12 fix round: Traefik takes 80/443 as hostPorts (iptables DNAT, no socket) behind a ClusterIP Service, so there is no
    # ServiceLB and no health check node port any more; any NodePort listener is a finding.
    $bad = foreach ($line in $lines) {
        $proto, $local = "$line" -split ' ', 2
        $address = $local -replace ':\d+$|:\*$', '' -replace '%[^\]]+', ''
        $port = ($local -split ':')[-1]
        $loopback = $address -match '^127\.' -or $address -in '[::1]', '::1'
        $allowed = $loopback -or ($proto -eq 'tcp' -and $port -eq '22' -and $address -in '0.0.0.0', '[::]', '*') -or
            ($proto -eq 'tcp' -and $address -eq $node -and $port -in '6443', '10250', '10256')
        if (-not $allowed) { "$proto $local" }
    }
    if ($bad) { throw "not allowed: $($bad -join ', ')" }
    # The VM's own IPv6 address: nothing but SSH answers there (curl exit 7 = connection refused).
    $v6 = ($hostInfo.ipv6 -split '/')[0]
    $http = Get-Ssh "for p in 80 443; do curl -6 -s -o /dev/null --max-time 5 http://[$v6]:`$p/; echo `$?; done"
    if (@($http | Where-Object { $_ -ne '7' }).Count) { throw "IPv6 [$v6]:80/443 answer (curl exit codes $($http -join ', ')), but there are no AAAA records" }
    "$($lines.Count) listeners, all on loopback or allowed; IPv6 [$v6]: 80/443 refused, only SSH"
}

Add-Check 'AppArmor: restrictions on, k3s runc has the runc profile, no stacked container labels, no container signal denials' {
    # Plan 08 Task 12 (cloud-init.yaml, /etc/apparmor.d/procure-k3s-runc): without the profile every non-root container ran as
    # cri-containerd.apparmor.d//&unconfined and could not signal its own processes (Postgres and MongoDB init failed).
    $out = Get-Ssh @'
sysctl -n kernel.apparmor_restrict_unprivileged_unconfined kernel.apparmor_restrict_unprivileged_userns
p=/var/lib/rancher/k3s/data/procure-aa-probe-$$; sudo rm -rf "$p"; sudo mkdir -p "$p/bin" && sudo cp /usr/bin/grep "$p/bin/runc" && echo "label=$(sudo "$p/bin/runc" '' /proc/self/attr/current 2>&1 | head -1)"; sudo rm -rf "$p"
test -L /etc/apparmor.d/disable/runc && echo ubuntu-runc-disabled || echo ubuntu-runc-enabled
ps -eo label= | grep -c '//&unconfined' || true
sudo journalctl -k --since "-10 min" --no-pager | grep -c 'apparmor="DENIED" operation="signal" class="signal" profile="cri-containerd' || true
'@
    $lines = @($out | Where-Object { "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() })
    $problems = @()
    if ($lines[0] -ne '1' -or $lines[1] -ne '1') { $problems += "restrict_unprivileged_unconfined $($lines[0]), restrict_unprivileged_userns $($lines[1]) (both must stay 1)" }
    # The attachment the kernel really uses: a copy of grep at a path of k3s's runc pattern (data/<dir>/bin/runc) prints its own AppArmor
    # label. 'runc (unconfined)' only when the loaded runc profile attaches to k3s's path; Ubuntu's own profile (/usr/{bin,sbin}/runc only)
    # or none at all gives 'unconfined' (Task 12 review: counting loaded runc profiles could not tell the two apart).
    if ($lines[2] -ne 'label=runc (unconfined)') { $problems += "a binary at k3s's runc path does not get the runc profile (/etc/apparmor.d/procure-k3s-runc not loaded?): '$($lines[2])'" }
    if ($lines[3] -ne 'ubuntu-runc-disabled') { $problems += "/etc/apparmor.d/disable/runc missing (two runc definitions)" }
    if ([int] $lines[4] -gt 0) { $problems += "$($lines[4]) processes with a stacked //&unconfined label (containers started without the profile; restart them)" }
    if ([int] $lines[5] -gt 0) { $problems += "$($lines[5]) container signal denials in the kernel log of the last 10 minutes" }
    if ($problems) { throw ($problems -join '; ') }
    'restrictions 1/1; the loaded runc profile attaches to k3s''s runc path (probe label runc (unconfined)); no stacked labels; no signal denials (10 min)'
}

Add-Check 'flannel uses host-gw (no VXLAN socket)' {
    $backend = (Get-Ssh "sudo k3s kubectl get node -o jsonpath='{.items[0].metadata.annotations.flannel\.alpha\.coreos\.com/backend-type}'") -join ''
    $vxlan = Get-Ssh "ip -br link show type vxlan | wc -l; ss -Hlnu 'sport = :8472' | wc -l"
    if ($backend -ne 'host-gw' -or ($vxlan -join ',') -ne '0,0') { throw "backend '$backend', vxlan links/sockets: $($vxlan -join ', ')" }
    'host-gw; no vxlan interface, nothing on UDP 8472'
}

Add-Check 'the IPv4 and IPv6 default routes use eth0, the interface the host firewall filters' {
    # The nftables rules match iifname "eth0"; with any other public interface name (a future image with predictable names) they would
    # let everything through.
    $routes = Get-Ssh 'ip -4 route show default | awk ''{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}''; echo ---; ip -6 route show default | awk ''{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}'''
    $v4 = @($routes | Select-Object -First ([array]::IndexOf(@($routes), '---')) | Where-Object { $_ })
    $v6 = @($routes | Select-Object -Skip ([array]::IndexOf(@($routes), '---') + 1) | Where-Object { $_ })
    if (-not $v4 -or @($v4 | Where-Object { $_ -ne 'eth0' })) { throw "IPv4 default route via '$($v4 -join ', ')', but the host firewall filters eth0: fix the interface name in /etc/procure/host-firewall.nft and cloud-init.yaml" }
    if (@($v6 | Where-Object { $_ -ne 'eth0' })) { throw "IPv6 default route via '$($v6 -join ', ')', but the host firewall filters eth0" }
    "IPv4 default via $($v4 -join ', '); IPv6 default via $(if ($v6) { $v6 -join ', ' } else { 'none' })"
}

Add-Check 'host firewall loaded (nftables inet procure_host: eth0 in 22/80/443 + replies, forward only 80/443)' {
    $active = (Get-Ssh 'systemctl is-active procure-host-firewall; systemctl is-enabled procure-host-firewall') -join ','
    $table = (Get-Ssh 'sudo nft list table inet procure_host') -join "`n"
    $problems = @()
    if ($active -ne 'active,enabled') { $problems += "service: $active" }
    foreach ($want in 'hook input', 'hook forward', 'iifname != "eth0" accept', 'tcp dport { 22, 80, 443 } accept', 'ct original proto-dst { 80, 443 } accept') {
        if ($table -notlike "*$want*") { $problems += "missing '$want'" }
    }
    if (([regex]::Matches($table, 'counter packets \d+ bytes \d+ drop')).Count -ne 2) { $problems += 'expected a final drop in both chains' }
    if ($problems) { throw ($problems -join '; ') }
    'service active and enabled; input: 22, 80, 443 and replies; forward: 80, 443 and replies; everything else on eth0 dropped'
}

Add-Check 'sudo group holds only the admin user; no ubuntu user' {
    $sudo = (Get-Ssh 'getent group sudo | cut -d: -f4') -join ''
    $ubuntu = (Get-Ssh 'id ubuntu >/dev/null 2>&1 && echo present || echo absent') -join ''
    if ($sudo -ne $hostInfo.user -or $ubuntu -ne 'absent') { throw "sudo group: '$sudo'; ubuntu user $ubuntu" }
    "sudo: $sudo; ubuntu absent"
}

Add-Check 'k3s without ServiceLB; no Service of type LoadBalancer' {
    # Plan 08 final review B M3: Traefik takes 80/443 as hostPorts; a LoadBalancer Service would get svclb host ports on every interface.
    $config = (Get-Ssh 'sudo cat /etc/rancher/k3s/config.yaml') -join "`n"
    $services = ((Get-Ssh 'sudo k3s kubectl get svc -A -o json') -join "`n" | ConvertFrom-Json).items
    $lb = @($services | Where-Object { $_.spec.type -eq 'LoadBalancer' } | ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" })
    $problems = @()
    if ($config -notmatch '(?m)^disable:\s*$' -or $config -notmatch '(?m)^\s*-\s*"?servicelb"?\s*$') { $problems += 'servicelb is not disabled in /etc/rancher/k3s/config.yaml (docs/hosting.md "Turning ServiceLB off")' }
    if ($lb) { $problems += "LoadBalancer Services: $($lb -join ', ')" }
    if ($problems) { throw ($problems -join '; ') }
    'servicelb disabled; no LoadBalancer Service'
}

Add-Check 'Traefik (public edge) has a memory limit' {
    $limit = (Get-Ssh "sudo k3s kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'") -join ''
    if (-not $limit) { throw 'no memory limit on kube-system/traefik (apply traefik-config.yaml: install-cert-manager.ps1 -Production)' }
    "memory limit $limit"
}

Add-Check 'certificate ingress-tls/procure-public Ready, from letsencrypt-production, more than 21 days left' {
    $cert = (Get-Ssh 'sudo k3s kubectl -n ingress-tls get certificate procure-public -o json') -join "`n" | ConvertFrom-Json
    $ready = @($cert.status.conditions | Where-Object type -eq 'Ready')[0]
    $notAfter = [datetime]::Parse($cert.status.notAfter, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $days = [int] [math]::Floor(($notAfter - [datetime]::UtcNow).TotalDays)
    $problems = @()
    if ($ready.status -ne 'True') { $problems += "Ready=$($ready.status) ($($ready.message))" }
    if ($cert.spec.issuerRef.name -ne 'letsencrypt-production') { $problems += "issuer $($cert.spec.issuerRef.name)" }
    if ($days -lt 21) { $problems += "$days days left (renewal due at 30 is failing: kubectl -n ingress-tls describe certificate,order,challenge)" }
    if ($problems) { throw ($problems -join '; ') }
    "Ready; $($cert.spec.issuerRef.name); $days days left (until $($notAfter.ToString('yyyy-MM-dd')))"
}

Add-Check "the PC's hosted kubeconfig: admin client certificate valid for more than 30 days" {
    # k3s renews its client certificates on a restart when they are within 90 days of expiry; the PC keeps the copy it fetched, which
    # then stops working on its expiry date. Fix: bootstrap/hosted/new-hosted-cluster.ps1 -KubeconfigOnly (after a k3s restart).
    if (-not (Test-Path $HostedKubeconfig)) { throw "no kubeconfig at $HostedKubeconfig" }
    $data = [regex]::Match((Get-Content -Raw $HostedKubeconfig), '(?m)^\s*client-certificate-data:\s*(\S+)').Groups[1].Value
    if (-not $data) { throw 'no client-certificate-data in the kubeconfig' }
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($data))
    $left = [int] [math]::Floor(($cert.NotAfter.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
    $cert.Dispose()
    if ($left -lt 30) { throw "$left days left: restart k3s at a quiet time (it renews), then new-hosted-cluster.ps1 -KubeconfigOnly" }
    "$left days left"
}

Add-Check "GHCR pull token not expired (expires $($GhcrPullTokenExpires.ToString('yyyy-MM-dd')))" {
    $left = [int] [math]::Floor(($GhcrPullTokenExpires - (Get-Date)).TotalDays)
    if ($left -lt 0) { throw "expired $(-$left) days ago: hosted deploys fail with ImagePullBackOff while the packages are private (bootstrap/common.ps1 GhcrPullTokenExpires says how to renew)" }
    if ($left -lt 21) {
        $results.Add([pscustomobject]@{ Result = 'WARN'; Check = 'GHCR pull token expires soon'; Detail = "$left days left; renew it (bootstrap/common.ps1 GhcrPullTokenExpires)" })
    }
    "$left days left"
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
    # From the PC over IPv6 only when the PC has working IPv6 (a route alone is not enough); the VM-side check above covers IPv6 anyway.
    $ipv6 = ($publicAddresses[1] -split '/')[0]
    if ($ipv6 -and (Test-Tcp '2606:4700:4700::1111' 443)) { $addresses += $ipv6 }
}
foreach ($address in $addresses) {
    Add-Check "from the PC: $address answers on 22, 80, 443 only (6443, 6444, 10250, 10256, 2379, 2380, 8080 closed)" {
        # IPv6 serves only SSH (no AAAA records); IPv4 serves 22, 80 and 443.
        $wantOpen = if ($address.Contains(':')) { @(22) } else { @(22, 80, 443) }
        $open = @(22, 80, 443) | Where-Object { Test-Tcp $address $_ }
        $closed = @(6443, 6444, 10250, 10256, 2379, 2380, 8080) | Where-Object { Test-Tcp $address $_ }
        $problems = @()
        if ((@($open) -join ',') -ne ($wantOpen -join ',')) { $problems += "open of 22/80/443: $($open -join ', '), expected $($wantOpen -join ', ')" }
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

Add-Check 'Cloudflare API: one A record each for procure, auth, dashboard to the server, not proxied; no AAAA' {
    if (-not $hostInfo) { throw 'no VM (host.json missing)' }
    $records = Get-HostedDnsRecords
    $problems = @()
    foreach ($h in @($HostedDnsHosts) + @($HostedRedirectHosts)) {
        $fqdn = Get-HostedFqdn $h
        $a = @($records | Where-Object { $_.name -eq $fqdn -and $_.type -eq 'A' })
        if ($a.Count -ne 1) { $problems += "A ${fqdn}: $($a.Count) records"; continue }
        if ($a[0].content -ne $hostInfo.ipv4) { $problems += "A $fqdn -> $($a[0].content), server is $($hostInfo.ipv4)" }
        if ($a[0].proxied) { $problems += "A $fqdn is proxied" }
    }
    $aaaa = @($records | Where-Object type -eq 'AAAA')
    if ($aaaa) { $problems += "AAAA records exist: $(($aaaa | ForEach-Object name) -join ', ')" }
    if ($problems) { throw ($problems -join '; ') }
    "$($records.Count) A records, all to $($hostInfo.ipv4), DNS only; no AAAA"
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "$($results.Count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
