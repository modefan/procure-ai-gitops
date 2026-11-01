#Requires -Version 7.4
<#
.SYNOPSIS
    Optional, for Dale only: trusts the local CA in the current user's certificate store, so browsers accept https://*.procure.localtest.me.
.DESCRIPTION
    Imports %USERPROFILE%\.procure-ai\local-ca\ca.crt into Cert:\CurrentUser\Root (Windows shows a confirmation dialog). -Remove takes it
    out again. Claude never runs this script: it changes the PC's trust store (plan 07 ruling 8). Without it the browser shows a
    certificate warning, and tests use ignoreHTTPSErrors. Firefox uses its own store unless security.enterprise_roots.enabled is true.
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch] $Remove)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$caCrt = Join-Path $env:USERPROFILE '.procure-ai\local-ca\ca.crt'
if (-not (Test-Path $caCrt)) { throw "$caCrt not found; run bootstrap/new-local-ca.ps1 first." }
$ca = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($caCrt)

if ($Remove) {
    $installed = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Thumbprint -eq $ca.Thumbprint)
    if (-not $installed) { Write-Host 'The local CA is not in Cert:\CurrentUser\Root.'; return }
    if ($PSCmdlet.ShouldProcess($ca.Subject, 'Remove from Cert:\CurrentUser\Root')) {
        $installed | Remove-Item
        Write-Host "Removed '$($ca.Subject)'."
    }
    return
}
if ($PSCmdlet.ShouldProcess($ca.Subject, 'Import into Cert:\CurrentUser\Root')) {
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    $store.Open('ReadWrite')
    try { $store.Add($ca) } finally { $store.Close() }
    Write-Host "Trusted '$($ca.Subject)' (thumbprint $($ca.Thumbprint)). Restart the browser."
}
