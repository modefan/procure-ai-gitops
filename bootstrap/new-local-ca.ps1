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
    Cluster objects (kubectl apply, so a second run reports "unchanged"):
      procure/Secret procure-tls (kubernetes.io/tls)   + procure/TLSStore default (Traefik's default certificate)
      procure/Secret mongo-tls   (tls.crt, tls.key, ca.crt, mongo.pem)
      procure and observability/ConfigMap procure-ca   (key <openssl subject hash>.0 for SSL_CERT_DIR, and ca.crt)
    Browsers do not trust this CA unless Dale imports it himself (trust-local-ca.ps1, optional).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ClusterReachable
$openssl = Get-OpenSsl

Set-CurrentUserOnlyAcl $LocalCaDir

function Invoke-OpenSsl {
    $out = & $openssl @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "openssl $($args[0]) failed: $($out -join [Environment]::NewLine)" }
}

function Test-CertificateCurrent([string] $path) {
    if (-not (Test-Path $path)) { return $false }
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($path)
    $cert.NotAfter -gt (Get-Date).AddDays(30)
}

$caKey = Join-Path $LocalCaDir 'ca.key'
$caCrt = Join-Path $LocalCaDir 'ca.crt'
$caCreated = $false
if (-not ((Test-Path $caKey) -and (Test-Path $caCrt))) {
    Write-Host 'Creating the local CA...'
    Invoke-OpenSsl req -x509 -new -newkey rsa:3072 -noenc -keyout $caKey -out $caCrt -days 3650 -sha256 `
        -subj '/O=procure-ai/CN=procure-ai local CA' `
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' `
        -addext 'keyUsage=critical,keyCertSign,cRLSign' `
        -addext 'subjectKeyIdentifier=hash'
    $caCreated = $true
}

function New-LeafCertificate([string] $name, [string] $commonName, [string[]] $altNames, [string] $extendedKeyUsage) {
    $key = Join-Path $LocalCaDir "$name.key"
    $crt = Join-Path $LocalCaDir "$name.crt"
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

New-LeafCertificate 'procure' 'procure.localtest.me' @('procure.localtest.me', '*.procure.localtest.me') 'serverAuth' | Out-Null
# mongod presents this to the services (mongo / the FQDN) and to itself (localhost, for mongosh in the pod and the init Job);
# mongo-0.mongo... covers a headless StatefulSet member name if the replica set is initiated with it.
$mongoIssued = New-LeafCertificate 'mongo' 'mongo.procure.svc.cluster.local' @(
    'mongo', 'mongo.procure', 'mongo.procure.svc', 'mongo.procure.svc.cluster.local',
    'mongo-0.mongo', 'mongo-0.mongo.procure.svc.cluster.local', 'localhost', '127.0.0.1') 'serverAuth,clientAuth'
$mongoPem = Join-Path $LocalCaDir 'mongo.pem'
if ($mongoIssued -or -not (Test-Path $mongoPem)) {
    # mongod --tlsCertificateKeyFile wants key and certificate in one file.
    $pem = (Get-Content -Raw (Join-Path $LocalCaDir 'mongo.key')) + (Get-Content -Raw (Join-Path $LocalCaDir 'mongo.crt'))
    [IO.File]::WriteAllText($mongoPem, $pem)
}

# --- Cluster objects ---
$hash = (& $openssl x509 -subject_hash -noout -in $caCrt).Trim()
if ($LASTEXITCODE -ne 0 -or $hash -notmatch '^[0-9a-f]{8}$') { throw 'Could not compute the CA subject hash.' }

Write-Host (Invoke-Apply (New-SecretObject -Namespace procure -Name procure-tls -Type 'kubernetes.io/tls' -FileData ([ordered]@{
    'tls.crt' = Join-Path $LocalCaDir 'procure.crt'
    'tls.key' = Join-Path $LocalCaDir 'procure.key'
})))
Write-Host (Invoke-Apply ([ordered]@{
    apiVersion = 'traefik.io/v1alpha1'
    kind       = 'TLSStore'
    # Traefik only uses the store named "default"; it becomes the certificate for every ingress without its own.
    metadata   = [ordered]@{ name = 'default'; namespace = 'procure'; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
    spec       = [ordered]@{ defaultCertificate = [ordered]@{ secretName = 'procure-tls' } }
}))
Write-Host (Invoke-Apply (New-SecretObject -Namespace procure -Name mongo-tls -Type 'kubernetes.io/tls' -FileData ([ordered]@{
    'tls.crt'   = Join-Path $LocalCaDir 'mongo.crt'
    'tls.key'   = Join-Path $LocalCaDir 'mongo.key'
    'ca.crt'    = $caCrt
    'mongo.pem' = $mongoPem
})))
$caPem = Get-Content -Raw $caCrt
foreach ($namespace in 'procure', 'observability') {
    Write-Host (Invoke-Apply ([ordered]@{
        apiVersion = 'v1'
        kind       = 'ConfigMap'
        metadata   = [ordered]@{ name = 'procure-ca'; namespace = $namespace; labels = [ordered]@{ 'app.kubernetes.io/managed-by' = 'procure-bootstrap' } }
        # <hash>.0 is how OpenSSL finds a CA in a directory (SSL_CERT_DIR=/etc/ssl/certs:/etc/procure-ca); ca.crt for keytool and the like.
        data       = [ordered]@{ "$hash.0" = $caPem; 'ca.crt' = $caPem }
    }))
}
Write-Host "Local CA in $LocalCaDir (subject hash $hash)."
