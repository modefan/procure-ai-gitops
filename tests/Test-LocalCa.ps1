#Requires -Version 7.4
<#
.SYNOPSIS
    The local CA of bootstrap/new-local-ca.ps1 may only vouch for the names the cluster uses (final review M4, plan 08 Task 3).
.DESCRIPTION
    Runs new-local-ca.ps1 -FilesOnly into a temporary folder (no cluster needed, %USERPROFILE%\.procure-ai\local-ca is not touched) and
    checks with openssl:
      1. The CA has a critical Name Constraints extension that permits exactly DNS:localtest.me (the browser hosts *.procure.localtest.me),
         the in-cluster names of MongoDB's certificate and 127.0.0.1, and nothing else.
      2. Both leaf certificates it issued (Traefik's wildcard, MongoDB's) verify against it (openssl enforces name constraints).
      3. A certificate the same CA signs for any other name (evil.example.com, or a 10.x address) does NOT verify: if the CA key ever
         leaks, or Dale imports the CA into a certificate store, it cannot be used to impersonate another site.
      4. A CA made by the old script (no name constraints) in the folder is replaced, with every leaf reissued; a second run changes nothing.
    Exit code 1 on any failure.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\bootstrap\common.ps1')
$openssl = Get-OpenSsl
$script = Join-Path $PSScriptRoot '..\bootstrap\new-local-ca.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string] $message) { $failures.Add($message); Write-Host "FAIL: $message" -ForegroundColor Red }
function Pass([string] $message) { Write-Host "ok:   $message" -ForegroundColor Green }

$expectedPermitted = @('DNS:localtest.me', 'DNS:mongo', 'DNS:mongo.procure', 'DNS:mongo.procure.svc', 'DNS:procure.svc.cluster.local',
    'DNS:localhost', 'IP:127.0.0.1/255.255.255.255')

function Get-Text([string] $path) { (& $openssl x509 -in $path -noout -text 2>&1) -join "`n" }
function Get-Fingerprint([string] $path) { "$(& $openssl x509 -in $path -noout -fingerprint -sha256 2>&1)" }
function Test-Verifies([string] $dir, [string] $leaf) {
    $out = & $openssl verify -CAfile (Join-Path $dir 'ca.crt') $leaf 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join ' ') }
}

function New-ForeignLeaf([string] $dir, [string] $name, [string] $san) {
    # A certificate the CA signs for a name the cluster does not use (what an attacker with the CA key would make).
    $key = Join-Path $dir "$name.key"; $csr = Join-Path $dir "$name.csr"; $crt = Join-Path $dir "$name.crt"; $ext = Join-Path $dir "$name.ext"
    @('basicConstraints=critical,CA:FALSE', 'keyUsage=critical,digitalSignature,keyEncipherment', 'extendedKeyUsage=serverAuth',
        "subjectAltName=$san") | Set-Content -Path $ext -Encoding ascii
    & $openssl req -new -newkey rsa:2048 -noenc -keyout $key -out $csr -subj "/CN=$name" 2>&1 | Out-Null
    & $openssl x509 -req -in $csr -CA (Join-Path $dir 'ca.crt') -CAkey (Join-Path $dir 'ca.key') -set_serial 0x01 -days 1 -sha256 `
        -extfile $ext -out $crt 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not sign the $name test certificate" }
    $crt
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("procure-ca-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    # --- 4 (setup). An old, unconstrained CA with a leaf, as the plan 07 script made them -----------------------------------------------
    $old = Join-Path $work 'old'
    New-Item -ItemType Directory -Path $old -Force | Out-Null
    & $openssl req -x509 -new -newkey rsa:2048 -noenc -keyout (Join-Path $old 'ca.key') -out (Join-Path $old 'ca.crt') -days 30 -sha256 `
        -subj '/O=procure-ai/CN=procure-ai local CA' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' `
        -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>&1 | Out-Null
    $oldCa = Get-Fingerprint (Join-Path $old 'ca.crt')

    $out = & pwsh -NoProfile -File $script -CaDir $old -FilesOnly 2>&1
    if ($LASTEXITCODE -ne 0) { throw "new-local-ca.ps1 -CaDir -FilesOnly failed: $($out -join [Environment]::NewLine)" }
    $dir = $old
    $caText = Get-Text (Join-Path $dir 'ca.crt')

    # --- 1. The name constraint ------------------------------------------------------------------------------------------------------
    if ($caText -match 'X509v3 Name Constraints: critical\s*\n\s*Permitted:\s*\n((?:\s+(?:DNS|IP):[^\n]+\n?)+)') {
        $permitted = @($Matches[1] -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $missing = @($expectedPermitted | Where-Object { $_ -notin $permitted })
        $extra = @($permitted | Where-Object { $_ -notin $expectedPermitted })
        if (-not $missing -and -not $extra) { Pass "CA name constraints (critical) permit exactly: $($permitted -join ', ')" }
        else { Fail "CA name constraints differ: missing [$($missing -join ', ')], unexpected [$($extra -join ', ')]" }
        if ($caText -match 'Excluded:') { Fail 'CA name constraints have an Excluded list (expected permitted only)' }
    } else {
        Fail "ca.crt has no critical Name Constraints extension with a Permitted list (openssl x509 -text)"
    }

    # --- 2. The leaves it issued verify --------------------------------------------------------------------------------------------
    foreach ($leaf in 'procure', 'mongo') {
        $v = Test-Verifies $dir (Join-Path $dir "$leaf.crt")
        if ($v.Ok) { Pass "$leaf.crt verifies against the constrained CA" } else { Fail "$leaf.crt does not verify: $($v.Output)" }
    }

    # --- 3. Anything else does not -----------------------------------------------------------------------------------------------------
    foreach ($case in @(@{ Name = 'evil.example.com'; San = 'DNS:evil.example.com' }, @{ Name = 'procure.localtest.me.evil.example'; San = 'DNS:procure.localtest.me.evil.example' },
            @{ Name = 'ip-leaf'; San = 'DNS:x.procure.localtest.me,IP:10.0.0.1' })) {
        $crt = New-ForeignLeaf $dir $case.Name $case.San
        $v = Test-Verifies $dir $crt
        if (-not $v.Ok -and $v.Output -match 'subtree violation|name constraint') { Pass "a certificate for $($case.San) signed by the CA is refused (name constraints)" }
        elseif (-not $v.Ok) { Fail "a certificate for $($case.San) is refused, but not for its name: $($v.Output)" }
        else { Fail "a certificate for $($case.San) signed by the CA verifies: the CA is not constrained" }
    }

    # --- 4. The old CA was replaced, a second run keeps the new one ---------------------------------------------------------------------
    $newCa = Get-Fingerprint (Join-Path $dir 'ca.crt')
    if ($newCa -ne $oldCa) { Pass 'the unconstrained CA in the folder was replaced' } else { Fail 'the unconstrained CA was kept' }
    $leafPrints = @{ procure = Get-Fingerprint (Join-Path $dir 'procure.crt'); mongo = Get-Fingerprint (Join-Path $dir 'mongo.crt') }
    $out = & pwsh -NoProfile -File $script -CaDir $dir -FilesOnly 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "second run failed: $($out -join ' ')" }
    elseif ((Get-Fingerprint (Join-Path $dir 'ca.crt')) -eq $newCa -and (Get-Fingerprint (Join-Path $dir 'procure.crt')) -eq $leafPrints.procure -and
        (Get-Fingerprint (Join-Path $dir 'mongo.crt')) -eq $leafPrints.mongo) { Pass 'a second run keeps the CA and both leaves' }
    else { Fail 'a second run replaced the CA or a leaf' }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) CA check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nLocal CA checks passed." -ForegroundColor Green
exit 0
