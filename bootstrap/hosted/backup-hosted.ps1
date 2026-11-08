#Requires -Version 7.4
<#
.SYNOPSIS
    Writes an encrypted offline copy of everything the hosted (and local) setup needs that exists only on Dale's PC (plan 08 final review
    B I4, ruling R4), or checks one (-Verify).
.DESCRIPTION
    Losing the PC (or %USERPROFILE%\.procure-ai) would otherwise leave only destructive ways back: without the SSH key only the Contabo VNC
    console reaches the VM, without the Terraform state only a reinstall adopts it, and the hosted Secrets (admin API key, database and
    Keycloak secrets, the Argo CD and MongoDB CAs) would be gone. The archive holds:
      %USERPROFILE%\.procure-ai\hosted\     SSH key pair, known_hosts, terraform.tfstate(.backup), host.json, kubeconfig, internal-ca\
                                            (not the tunnel PID, logs or WAL-test files)
      %USERPROFILE%\.procure-ai\deploy-keys\ Argo CD's and CI's deploy keys (local and hosted)
      %USERPROFILE%\.procure-ai\local-ca\   the local cluster's CA
      %APPDATA%\Microsoft\UserSecrets\procure-ai-hosted\secrets.json and ...\procure-ai-apphost\secrets.json
      %USERPROFILE%\Desktop\DEMO PASSWORDS.txt
    It is a tar.gz encrypted with GnuPG (symmetric AES-256, passphrase-derived key; gpg ships with Git for Windows, nothing to install) and
    named procure-ai-offline-<yyyyMMdd-HHmm>.tar.gz.gpg. The plaintext archive exists only for the seconds of the run, in a temporary folder
    only the current user can read, and is deleted afterwards. The passphrase is the DEMO PASSWORDS.txt entry "Offline backup passphrase"
    (section "procure-ai offline backup"), generated on the first run (40 letters and digits, never printed). Dale must ALSO keep it
    somewhere off this PC (his password manager or on paper): the copy inside DEMO PASSWORDS.txt is inside the archive it opens.

    -Destination is required and has no default: WHERE the archive is kept is Dale's call (a USB drive, a second disk, a cloud folder he
    already uses; procure-ai docs/hosting.md "Offline backup"). The script refuses a folder inside a git repository and the Desktop.
    -Verify <archive>: decrypts into a temporary current-user-only folder, lists the files it holds (names only) and deletes them again.
    Restore: procure-ai docs/hosting.md, "Recovering the hosted setup". Prints no secret.
#>
[CmdletBinding(DefaultParameterSetName = 'Backup')]
param(
    [Parameter(ParameterSetName = 'Backup', Mandatory)] [string] $Destination,
    [Parameter(ParameterSetName = 'Verify', Mandatory)] [string] $Verify
)

. (Join-Path $PSScriptRoot '..\common.ps1')

$gpg = @((Get-Command gpg -ErrorAction SilentlyContinue)?.Source, 'C:\Program Files\Git\usr\bin\gpg.exe') | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $gpg) { throw 'gpg not found (Git for Windows ships it in C:\Program Files\Git\usr\bin).' }
$tar = "$env:SystemRoot\System32\tar.exe"
if (-not (Test-Path $tar)) { throw "Windows' tar.exe not found." }
$section = 'procure-ai offline backup'
$key = 'Offline backup passphrase'

function Get-Passphrase([switch] $Create) {
    # The passphrase from DEMO PASSWORDS.txt (never printed); created on the first backup.
    $inSection = $false
    if (Test-Path $DemoPasswordsFile) {
        foreach ($line in [IO.File]::ReadLines($DemoPasswordsFile)) {
            if ($line.StartsWith('===')) { $inSection = $line.StartsWith("=== $section"); continue }
            # "<key> (<note>): <value>"; the note holds no ': '.
            if ($inSection -and $line.TrimStart().StartsWith($key) -and $line.Contains(': ')) { return $line.Substring($line.IndexOf(': ') + 2).Trim() }
        }
    }
    if (-not $Create) { throw "No '$key' in section '$section' of $DemoPasswordsFile (type it from where Dale keeps it into that entry, then run again)." }
    $value = [Security.Cryptography.RandomNumberGenerator]::GetString([char[]] 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', 40)
    Set-DemoPasswordEntry -Section $section -Key $key -Label "$key (gpg AES-256, Dale keeps a copy off this PC too)" -Value $value
    Write-Host "New passphrase generated and stored in DEMO PASSWORDS.txt ('$key'). Dale: copy it somewhere off this PC as well."
    $value
}

function Invoke-Gpg([string[]] $gpgArgs, [string] $passphrase) {
    # The passphrase goes in on stdin (--passphrase-fd 0), never on the command line.
    $out = $passphrase | & $gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 0 @gpgArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gpg failed: $($out -join ' ')" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "procure-backup-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
Set-CurrentUserOnlyAcl $work
try {
    if ($Verify) {
        $archive = (Resolve-Path $Verify).Path
        Invoke-Gpg @('--decrypt', '--output', (Join-Path $work 'backup.tar.gz'), $archive) (Get-Passphrase)
        $files = & $tar -tzf (Join-Path $work 'backup.tar.gz') 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tar could not read the decrypted archive: $($files -join ' ')" }
        $files = @($files | ForEach-Object { "$_" -replace '^\./', '' } | Where-Object { $_ -and -not $_.EndsWith('/') })
        $files | ForEach-Object { Write-Host "  $_" }
        foreach ($must in 'procure-ai/hosted/procure-hosted_ed25519', 'procure-ai/hosted/terraform.tfstate', 'user-secrets/procure-ai-hosted/secrets.json', 'DEMO PASSWORDS.txt') {
            if ($must -notin $files) { throw "The archive lacks $must." }
        }
        Write-Host "OK: $archive decrypts with the passphrase and holds $($files.Count) files, including the SSH key, the Terraform state, the hosted user secrets and DEMO PASSWORDS.txt."
        return
    }

    $Destination = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path $Destination -PathType Container)) { throw "Destination folder $Destination does not exist (Dale chooses it; create it first)." }
    for ($dir = Get-Item $Destination; $dir; $dir = $dir.Parent) {
        if (Test-Path (Join-Path $dir.FullName '.git')) { throw "$Destination is inside the git repository $($dir.FullName): never put the backup in a repo." }
    }
    if ($Destination.TrimEnd('\') -eq (Join-Path $env:USERPROFILE 'Desktop')) { throw 'Not the Desktop: the backup is for a place off this PC.' }
    $passphrase = Get-Passphrase -Create

    # Stage the files under stable names (the tar paths), in the current-user-only folder.
    $stage = Join-Path $work 'stage'
    $procure = Join-Path $env:USERPROFILE '.procure-ai'
    $copies = [ordered]@{
        'procure-ai/deploy-keys'                   = Join-Path $procure 'deploy-keys'
        'procure-ai/local-ca'                      = Join-Path $procure 'local-ca'
        'user-secrets/procure-ai-hosted/secrets.json'  = Join-Path $env:APPDATA "Microsoft\UserSecrets\$HostedUserSecretsId\secrets.json"
        'user-secrets/procure-ai-apphost/secrets.json' = Join-Path $env:APPDATA "Microsoft\UserSecrets\$AppHostUserSecretsId\secrets.json"
        'DEMO PASSWORDS.txt'                        = $DemoPasswordsFile
    }
    foreach ($name in 'procure-hosted_ed25519', 'procure-hosted_ed25519.pub', 'known_hosts', 'terraform.tfstate', 'terraform.tfstate.backup', 'host.json', 'kubeconfig', 'internal-ca') {
        $copies["procure-ai/hosted/$name"] = Join-Path $procure "hosted\$name"
    }
    $missing = @()
    foreach ($target in $copies.Keys) {
        $source = $copies[$target]
        if (-not (Test-Path $source)) { $missing += $source; continue }
        $to = Join-Path $stage $target
        New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
        Copy-Item -Recurse -Force -LiteralPath $source -Destination $to
    }
    foreach ($required in 'procure-ai/hosted/procure-hosted_ed25519', 'procure-ai/hosted/terraform.tfstate', 'user-secrets/procure-ai-hosted/secrets.json', 'DEMO PASSWORDS.txt') {
        if (-not (Test-Path (Join-Path $stage $required))) { throw "Nothing to back up at $($copies[$required])." }
    }
    $plain = Join-Path $work 'backup.tar.gz'
    $out = & $tar -czf $plain -C $stage . 2>&1
    if ($LASTEXITCODE -ne 0) { throw "tar failed: $($out -join ' ')" }
    $count = @(Get-ChildItem -Recurse -File $stage).Count
    $name = "procure-ai-offline-$(Get-Date -Format 'yyyyMMdd-HHmm').tar.gz.gpg"
    $archive = Join-Path $Destination $name
    Invoke-Gpg @('--symmetric', '--cipher-algo', 'AES256', '--s2k-mode', '3', '--s2k-digest-algo', 'SHA512', '--s2k-count', '65011712', '--output', $archive, $plain) $passphrase
    Write-Host "Backup written: $archive ($count files, $([math]::Round((Get-Item $archive).Length / 1KB)) KiB, gpg AES-256)$(if ($missing) { "; not present, skipped: $($missing -join ', ')" })."
    Write-Host "Check it: bootstrap/hosted/backup-hosted.ps1 -Verify '$archive'. Rerun after a reinstall, a new secret or a new deploy key."
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
