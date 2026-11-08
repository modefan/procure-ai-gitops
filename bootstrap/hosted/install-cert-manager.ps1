#Requires -Version 7.4
<#
.SYNOPSIS
    The hosted VM's edge: Traefik's redirect and client address, the CoreDNS rewrite, cert-manager, the Let's Encrypt issuers and the
    public certificate (plan 08 Task 12).
.DESCRIPTION
    Run after new-hosted-cluster.ps1 (through the SSH tunnel), before or after install-argocd.ps1 -Environment hosted. Safe to run again.
    1. Traefik (k3s's bundled chart): HelmChartConfig kube-system/traefik (traefik-config.yaml): http -> https redirect, HSTS, 80/443 as
       hostPorts with a ClusterIP Service (no ServiceLB, so the visitor's own address reaches X-Forwarded-For); waits for the rollout.
    2. CoreDNS: ConfigMap kube-system/coredns-custom (coredns-custom.yaml): auth.<domain> -> Traefik inside the cluster.
    3. cert-manager $CertManagerVersion from the official OCI chart (oci://quay.io/jetstack/charts/cert-manager), CRDs by the chart
       (crds.enabled, kept on uninstall), in namespace cert-manager, with memory limits.
    4. ClusterIssuers letsencrypt-staging and letsencrypt-production (ACME, HTTP-01 through an Ingress of class traefik). The ACME account
       e-mail comes from the user env var PROCURE_ACME_EMAIL (not in the repo); without it the accounts are registered without one
       (Let's Encrypt sends no expiry mails any more, so nothing is lost).
    5. Namespace ingress-tls (no NetworkPolicies, so cert-manager's HTTP-01 solver pod is reachable from Traefik; procure denies by default):
       Certificate procure-public for procure, auth and dashboard.<domain> (one certificate, one ACME order) from the chosen issuer, Secret
       procure-public-tls, and TLSStore ingress-tls/default pointing at it: Traefik's default certificate, the one every Ingress without its
       own secretName gets - the hosted twin of the local CA's TLSStore (bootstrap/new-local-ca.ps1). The charts stay unchanged.
       Waits until the Certificate is Ready and prints its issuer and dates.
    The certificate comes from the staging issuer unless -Production is given (Let's Encrypt's staging CA: untrusted, but no rate limits
    that matter); switch to production once staging issued for every host. Changing the issuer reissues the certificate, so a run without
    -Production refuses to downgrade a certificate that already comes from production (a rebuild of the VM starts with staging again, and a
    re-run on a live VM must say -Production; Let's Encrypt allows 5 duplicate certificates a week). Prints names only; nothing secret.
.EXAMPLE
    ./bootstrap/hosted/install-cert-manager.ps1               # staging certificate (fresh VM)
    ./bootstrap/hosted/install-cert-manager.ps1 -Production   # once staging worked for every host, and on every later run
#>
[CmdletBinding()]
param(
    # Request the certificate from Let's Encrypt production; without it, staging.
    [switch] $Production,
    [string] $CertManagerVersion = '1.21.3',
    [int] $TimeoutMinutes = 10
)

. (Join-Path $PSScriptRoot '..\common.ps1')
Select-ProcureCluster hosted
Assert-ClusterReachable

$namespace = 'ingress-tls'
$hosts = @($HostedDnsHosts | ForEach-Object { "$_.$HostedDomain" })
$Issuer = if ($Production) { 'production' } else { 'staging' }
$issuerName = "letsencrypt-$Issuer"
if (-not $Production) {
    $current = & kubectl @KubectlArgs -n $namespace get certificate procure-public -o jsonpath='{.spec.issuerRef.name}' 2>$null
    if ($current -eq 'letsencrypt-production') {
        throw "Certificate $namespace/procure-public already comes from letsencrypt-production; a run without -Production would replace it with an untrusted staging certificate. Run with -Production."
    }
}

# --- 1. Traefik -----------------------------------------------------------------------------------------------------------------------
$before = & kubectl @KubectlArgs -n kube-system get deployment traefik -o jsonpath='{.metadata.generation}' 2>$null
Write-Host (Invoke-ServerSideApply -Path (Join-Path $PSScriptRoot 'traefik-config.yaml') -Description 'HelmChartConfig kube-system/traefik')
# k3s's helm controller reruns the chart install when the config changes; wait for it to apply both settings.
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    $type = & kubectl @KubectlArgs -n kube-system get service traefik -o jsonpath='{.spec.type}' 2>$null
    $hostPorts = & kubectl @KubectlArgs -n kube-system get deployment traefik -o jsonpath='{.spec.template.spec.containers[0].ports[*].hostPort}' 2>$null
    $args0 = & kubectl @KubectlArgs -n kube-system get deployment traefik -o jsonpath='{.spec.template.spec.containers[0].args}' 2>$null
    $hostPortsOk = (@("$hostPorts" -split '\s+') -contains '80') -and (@("$hostPorts" -split '\s+') -contains '443')
    if ($type -eq 'ClusterIP' -and $hostPortsOk -and "$args0" -match 'entryPoints\.web\.http\.redirections\.entryPoint\.to=:?(websecure|443)' -and
        "$args0" -match 'entryPoints\.websecure\.http\.middlewares=kube-system-hsts@kubernetescrd') { break }
    if ((Get-Date) -gt $deadline) { throw "Traefik did not pick up traefik-config.yaml within 5 minutes (Service type '$type', hostPorts '$hostPorts'; kubectl -n kube-system logs job/helm-install-traefik)." }
    Start-Sleep -Seconds 5
}
Invoke-Kubectl -n kube-system rollout status deployment/traefik --timeout=300s | Out-Null
$after = & kubectl @KubectlArgs -n kube-system get deployment traefik -o jsonpath='{.metadata.generation}' 2>$null
Write-Host "Traefik: http -> https redirect, HSTS, hostPorts 80/443 with a ClusterIP Service$(if ($before -ne $after) { ' (rolled out)' } else { ' (unchanged)' })."

# --- 2. CoreDNS ----------------------------------------------------------------------------------------------------------------------
$corednsData = { & kubectl @KubectlArgs -n kube-system get configmap coredns-custom -o jsonpath='{.data}' 2>$null }
$before = & $corednsData
Write-Host (Invoke-ServerSideApply -Path (Join-Path $PSScriptRoot 'coredns-custom.yaml') -Description 'ConfigMap kube-system/coredns-custom')
if ($before -ne (& $corednsData)) {
    Invoke-Kubectl -n kube-system rollout restart deployment/coredns | Out-Null
    Invoke-Kubectl -n kube-system rollout status deployment/coredns --timeout=180s | Out-Null
    Write-Host 'coredns restarted'
}

# --- 3. cert-manager -------------------------------------------------------------------------------------------------------------------
Write-Host "Installing cert-manager $CertManagerVersion..."
$out = & helm @HelmArgs upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version $CertManagerVersion `
    --namespace cert-manager --create-namespace `
    --set crds.enabled=true --set crds.keep=true `
    --set resources.requests.cpu=10m --set resources.requests.memory=64Mi --set resources.limits.memory=256Mi `
    --set webhook.resources.requests.cpu=10m --set webhook.resources.requests.memory=32Mi --set webhook.resources.limits.memory=128Mi `
    --set cainjector.resources.requests.cpu=10m --set cainjector.resources.requests.memory=64Mi --set cainjector.resources.limits.memory=256Mi `
    --wait --timeout 10m 2>&1
if ($LASTEXITCODE -ne 0) { throw "helm upgrade --install cert-manager failed: $($out -join [Environment]::NewLine)" }
Write-Host 'cert-manager is running.'

# --- 4. ClusterIssuers -----------------------------------------------------------------------------------------------------------------
$email = [Environment]::GetEnvironmentVariable('PROCURE_ACME_EMAIL') ?? [Environment]::GetEnvironmentVariable('PROCURE_ACME_EMAIL', 'User')
$servers = [ordered]@{
    staging    = 'https://acme-staging-v02.api.letsencrypt.org/directory'
    production = 'https://acme-v02.api.letsencrypt.org/directory'
}
foreach ($kind in $servers.Keys) {
    $acme = [ordered]@{
        server              = $servers[$kind]
        privateKeySecretRef = [ordered]@{ name = "letsencrypt-$kind-account" }
        solvers             = @([ordered]@{ http01 = [ordered]@{ ingress = [ordered]@{ ingressClassName = 'traefik' } } })
    }
    if ($email) { $acme.email = $email }
    Write-Host (Invoke-Apply ([ordered]@{
        apiVersion = 'cert-manager.io/v1'
        kind       = 'ClusterIssuer'
        metadata   = [ordered]@{ name = "letsencrypt-$kind"; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
        spec       = [ordered]@{ acme = $acme }
    }))
}
$deadline = (Get-Date).AddMinutes(3)
while ((& kubectl @KubectlArgs get clusterissuer $issuerName -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>$null) -ne 'True') {
    if ((Get-Date) -gt $deadline) { throw "ClusterIssuer $issuerName is not Ready (kubectl describe clusterissuer $issuerName)." }
    Start-Sleep -Seconds 5
}
Write-Host "ClusterIssuer $issuerName Ready (ACME account registered$(if ($email) { ' with the PROCURE_ACME_EMAIL address' } else { ', no e-mail' }))."

# --- 5. The public certificate and Traefik's default TLSStore ------------------------------------------------------------------------
Write-Host (Invoke-Apply (New-NamespaceObject $namespace))
Write-Host (Invoke-Apply ([ordered]@{
    apiVersion = 'cert-manager.io/v1'
    kind       = 'Certificate'
    metadata   = [ordered]@{ name = 'procure-public'; namespace = $namespace; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
    spec       = [ordered]@{
        secretName = 'procure-public-tls'
        dnsNames   = $hosts
        issuerRef  = [ordered]@{ kind = 'ClusterIssuer'; name = $issuerName; group = 'cert-manager.io' }
        privateKey = [ordered]@{ algorithm = 'ECDSA'; size = 256; rotationPolicy = 'Always' }
    }
}))
Write-Host (Invoke-Apply ([ordered]@{
    apiVersion = 'traefik.io/v1alpha1'
    kind       = 'TLSStore'
    # Traefik uses only the store named "default" (one per cluster); its certificate serves every Ingress without its own.
    metadata   = [ordered]@{ name = 'default'; namespace = $namespace; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
    spec       = [ordered]@{ defaultCertificate = [ordered]@{ secretName = 'procure-public-tls' } }
}))

Write-Host "Waiting for Certificate $namespace/procure-public from $issuerName (at most $TimeoutMinutes min)..."
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ($true) {
    $cert = Invoke-Kubectl -n $namespace get certificate procure-public -o json | Out-String | ConvertFrom-Json
    $ready = @($cert.status.conditions | Where-Object { $_.type -eq 'Ready' }) | Select-Object -First 1
    $secretIssuer = & kubectl @KubectlArgs -n $namespace get secret procure-public-tls -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}' 2>$null
    if ($ready -and $ready.status -eq 'True' -and $secretIssuer -eq $issuerName) { break }
    if ((Get-Date) -gt $deadline) {
        $orders = & kubectl @KubectlArgs -n $namespace get certificaterequests,orders,challenges 2>&1
        throw "Certificate procure-public not Ready from $issuerName within $TimeoutMinutes min: $($ready.message)`n$($orders -join [Environment]::NewLine)"
    }
    Start-Sleep -Seconds 10
}
$pem = & kubectl @KubectlArgs -n $namespace get secret procure-public-tls -o jsonpath='{.data.tls\.crt}'
$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($pem))
Write-Host "Certificate procure-public Ready: $($hosts -join ', '); issuer $($x509.Issuer); valid $($x509.NotBefore.ToString('yyyy-MM-dd')) to $($x509.NotAfter.ToString('yyyy-MM-dd')); renewal $($cert.status.renewalTime)."
