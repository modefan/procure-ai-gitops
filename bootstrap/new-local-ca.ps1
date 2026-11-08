#Requires -Version 7.4
<#
.SYNOPSIS
    Creates (once) the local CA and its certificates in %USERPROFILE%\.procure-ai\local-ca\ and writes them into the cluster.
.DESCRIPTION
    Files (never in a repo; the folder is readable by the current user only):
      ca.key / ca.crt          the local CA (10 years)
      procure.key / .crt       wildcard *.procure.localtest.me + procure.localtest.me (Traefik's default certificate)
      mongo.key / .crt / .pem  MongoDB server certificate for mongo / mongo.procure.svc.cluster.local (.pem = key + certificate)
    Existing files are kept; a leaf certificate is reissued only when it expires within 30 days.
    The CA may only vouch for the names the cluster uses (X.509 name constraints, critical; final review M4): DNS localtest.me and its
    subdomains (every *.procure.localtest.me host), the in-cluster names on MongoDB's certificate (mongo, mongo.procure,
    mongo.procure.svc, procure.svc.cluster.local and below them, localhost) and the address 127.0.0.1. A certificate signed for any other
    name fails validation in OpenSSL, .NET, Java, Go and Windows, so the CA is harmless if Dale imports it (trust-local-ca.ps1) or its key
    leaks. A CA in the folder without exactly these constraints (one made before plan 08) is replaced, and every leaf with it.
    Cluster objects (kubectl apply, so a second run reports "unchanged"):
      procure/Secret procure-tls (kubernetes.io/tls)   + procure/TLSStore default (Traefik's default certificate)
      procure/Secret mongo-tls   (tls.crt, tls.key, ca.crt, mongo.pem)
      procure, observability and (local only) argocd/ConfigMap procure-ca   (key <openssl subject hash>.0 for SSL_CERT_DIR, and ca.crt)
    Browsers do not trust this CA unless Dale imports it himself (trust-local-ca.ps1, optional).
    -CaDir and -FilesOnly (tests/Test-LocalCa.ps1): write the files into another folder and leave the cluster alone.

    -Environment hosted (plan 08 Task 12): the hosted VM's own internal CA in %USERPROFILE%\.procure-ai\hosted\internal-ca\ (shares
    nothing with the local one), for MongoDB's TLS only: its name constraints hold only the in-cluster MongoDB names, localhost and
    127.0.0.1 (no localtest.me), and it issues no ingress certificate and writes no procure-tls / TLSStore (the public certificate is Let's
    Encrypt's, bootstrap/hosted/install-cert-manager.ps1). It writes mongo-tls and the procure-ca ConfigMaps on the hosted cluster.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'hosted')]
    [string] $Environment = 'local',
    [string] $CaDir,
    # Only the files: no cluster needed, no cluster objects written.
    [switch] $FilesOnly
)

. (Join-Path $PSScriptRoot 'common.ps1')
$hosted = $Environment -eq 'hosted'
if (-not $CaDir) { $CaDir = if ($hosted) { Join-Path $HostedDir 'internal-ca' } else { $LocalCaDir } }
if (-not $FilesOnly) { Select-ProcureCluster $Environment; Assert-ClusterReachable }
$openssl = Get-OpenSsl

Set-CurrentUserOnlyAcl $CaDir

# What the CA may sign (see the description); Test-LocalCa.ps1 checks the same list.
$permittedNames = @('DNS:localtest.me', 'DNS:mongo', 'DNS:mongo.procure', 'DNS:mongo.procure.svc', 'DNS:procure.svc.cluster.local',
    'DNS:localhost', 'IP:127.0.0.1/255.255.255.255')
# The hosted CA vouches for MongoDB's in-cluster names only (no host a browser opens).
if ($hosted) { $permittedNames = @($permittedNames | Where-Object { $_ -ne 'DNS:localtest.me' }) }
$caName = if ($hosted) { 'procure-ai hosted internal CA' } else { 'procure-ai local CA' }

function Invoke-OpenSsl {
    $out = & $openssl @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "openssl $($args[0]) failed: $($out -join [Environment]::NewLine)" }
}

function Test-CertificateCurrent([string] $path) {
    if (-not (Test-Path $path)) { return $false }
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($path)
    $cert.NotAfter -gt (Get-Date).AddDays(30)
}

function Test-CaConstrained([string] $path) {
    # True when the CA carries exactly $permittedNames as its (critical) permitted subtrees and nothing excluded.
    $text = (& $openssl x509 -in $path -noout -text 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($text -notmatch 'X509v3 Name Constraints: critical\s*\n\s*Permitted:\s*\n((?:\s+(?:DNS|IP):[^\n]+\n?)+)') { return $false }
    if ($text -match 'Excluded:') { return $false }
    $found = @($Matches[1] -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
    ($found -join ',') -eq ((@($permittedNames) | Sort-Object) -join ',')
}

$caKey = Join-Path $CaDir 'ca.key'
$caCrt = Join-Path $CaDir 'ca.crt'
$caCreated = $false
$caExists = (Test-Path $caKey) -and (Test-Path $caCrt)
if ($caExists -and -not (Test-CaConstrained $caCrt)) {
    Write-Host 'The local CA has no (or other) name constraints: replacing it and every certificate it issued...'
    $caExists = $false
}
if (-not $caExists) {
    Write-Host "Creating the $caName..."
    Invoke-OpenSsl req -x509 -new -newkey rsa:3072 -noenc -keyout $caKey -out $caCrt -days 3650 -sha256 `
        -subj "/O=procure-ai/CN=$caName" `
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' `
        -addext 'keyUsage=critical,keyCertSign,cRLSign' `
        -addext 'subjectKeyIdentifier=hash' `
        -addext ('nameConstraints=critical,' + (($permittedNames | ForEach-Object { "permitted;$_" }) -join ','))
    $caCreated = $true
}

function New-LeafCertificate([string] $name, [string] $commonName, [string[]] $altNames, [string] $extendedKeyUsage) {
    $key = Join-Path $CaDir "$name.key"
    $crt = Join-Path $CaDir "$name.crt"
    # A new CA invalidates every certificate the old one issued.
    if (-not $caCreated -and (Test-Path $key) -and (Test-CertificateCurrent $crt)) { return $false }
    Write-Host "Issuing $name certificate ($($altNames -join ', '))..."
    $work = Join-Path ([IO.Path]::GetTempPath()) ("procure-ca-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        # Only the request and the extension list go to the temp folder; the key is written straight into the CA folder.
        $csr = Join-Path $work "$name.csr"
        $ext = Join-Path $work "$name.ext"
        @(
            'basicConstraints=critical,CA:FALSE'
            'keyUsage=critical,digitalSignature,keyEncipherment'
            "extendedKeyUsage=$extendedKeyUsage"
            'subjectKeyIdentifier=hash'
            'authorityKeyIdentifier=keyid'
            'subjectAltName=' + (($altNames | ForEach-Object { if ($_ -match '^\d+\.\d+\.\d+\.\d+$') { "IP:$_" } else { "DNS:$_" } }) -join ',')
        ) | Set-Content -Path $ext -Encoding ascii
        Invoke-OpenSsl req -new -newkey rsa:2048 -noenc -keyout $key -out $csr -subj "/O=procure-ai/CN=$commonName"
        $serial = '0x' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
        # 397 days: within what browsers accept for a TLS certificate; reissued automatically 30 days before it ends.
        Invoke-OpenSsl x509 -req -in $csr -CA $caCrt -CAkey $caKey -set_serial $serial -days 397 -sha256 -extfile $ext -out $crt
    } finally {
        Remove-Item -Recurse -Force $work
    }
    $true
}

if (-not $hosted) { New-LeafCertificate 'procure' 'procure.localtest.me' @('procure.localtest.me', '*.procure.localtest.me') 'serverAuth' | Out-Null }
# mongod presents this to the services (mongo / the FQDN) and to itself (localhost, for mongosh in the pod and the init Job);
# mongo-0.mongo... covers a headless StatefulSet member name if the replica set is initiated with it.
$mongoIssued = New-LeafCertificate 'mongo' 'mongo.procure.svc.cluster.local' @(
    'mongo', 'mongo.procure', 'mongo.procure.svc', 'mongo.procure.svc.cluster.local',
    'mongo-0.mongo', 'mongo-0.mongo.procure.svc.cluster.local', 'localhost', '127.0.0.1') 'serverAuth,clientAuth'
$mongoPem = Join-Path $CaDir 'mongo.pem'
if ($mongoIssued -or -not (Test-Path $mongoPem)) {
    # mongod --tlsCertificateKeyFile wants key and certificate in one file.
    $pem = (Get-Content -Raw (Join-Path $CaDir 'mongo.key')) + (Get-Content -Raw (Join-Path $CaDir 'mongo.crt'))
    [IO.File]::WriteAllText($mongoPem, $pem)
}

if ($FilesOnly) {
    Write-Host "Local CA in $CaDir (files only, no cluster objects)."
    return
}

# --- Cluster objects ---
$hash = (& $openssl x509 -subject_hash -noout -in $caCrt).Trim()
if ($LASTEXITCODE -ne 0 -or $hash -notmatch '^[0-9a-f]{8}$') { throw 'Could not compute the CA subject hash.' }

if (-not $hosted) {
    Write-Host (Invoke-Apply (New-SecretObject -Namespace procure -Name procure-tls -Type 'kubernetes.io/tls' -FileData ([ordered]@{
        'tls.crt' = Join-Path $CaDir 'procure.crt'
        'tls.key' = Join-Path $CaDir 'procure.key'
    })))
    Write-Host (Invoke-Apply ([ordered]@{
        apiVersion = 'traefik.io/v1alpha1'
        kind       = 'TLSStore'
        # Traefik only uses the store named "default"; it becomes the certificate for every ingress without its own.
        metadata   = [ordered]@{ name = 'default'; namespace = 'procure'; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
        spec       = [ordered]@{ defaultCertificate = [ordered]@{ secretName = 'procure-tls' } }
    }))
}
Write-Host (Invoke-Apply (New-SecretObject -Namespace procure -Name mongo-tls -Type 'kubernetes.io/tls' -FileData ([ordered]@{
    'tls.crt'   = Join-Path $CaDir 'mongo.crt'
    'tls.key'   = Join-Path $CaDir 'mongo.key'
    'ca.crt'    = $caCrt
    'mongo.pem' = $mongoPem
})))
$caPem = Get-Content -Raw $caCrt
# argocd (local only): Argo CD's server checks Keycloak's certificate when it reads the OIDC issuer (envs/local/argocd.yaml, Task 12c); the
# hosted issuer has a Let's Encrypt certificate.
$caNamespaces = @('procure', 'observability') + @(if (-not $hosted) { 'argocd' })
foreach ($namespace in $caNamespaces) {
    Write-Host (Invoke-Apply ([ordered]@{
        apiVersion = 'v1'
        kind       = 'ConfigMap'
        metadata   = [ordered]@{ name = 'procure-ca'; namespace = $namespace; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
        # <hash>.0 is how OpenSSL finds a CA in a directory (SSL_CERT_DIR=/etc/ssl/certs:/etc/procure-ca); ca.crt for keytool and the like.
        data       = [ordered]@{ "$hash.0" = $caPem; 'ca.crt' = $caPem }
    }))
}
Write-Host "$(if ($hosted) { 'Hosted internal' } else { 'Local' }) CA in $CaDir (subject hash $hash)."
