#Requires -Version 7.4
<#
.SYNOPSIS
    Mirrors everything the hosted (and local) setup needs that exists only on Dale's PC into two folders off the Desktop, plain files (no
    encryption: Dale's decision 2026-11-08), then hash-compares every copy with its original. -Check only compares.
.DESCRIPTION
    Losing the PC (or %USERPROFILE%\.procure-ai) would otherwise leave only destructive ways back: without the SSH key only the Contabo VNC
    console reaches the VM, without the Terraform state only a reinstall adopts it, and the hosted Secrets would be gone (plan 08 final
    review B I4). The copies go to BOTH
      C:\Users\User\OneDrive\procure-ai secrets      (OneDrive: off the PC)
      C:\Users\User\Documents\procure-ai secrets     (a second local copy)
    each with this layout:
      DEMO PASSWORDS.txt                  <- %USERPROFILE%\Desktop\DEMO PASSWORDS.txt
      hosted\                             <- %USERPROFILE%\.procure-ai\hosted (not its run-time files: tunnel.pid, argocd-opened-tunnel,
                                             *.log, WAL-test scripts and folders)
      deploy-keys\                        <- %USERPROFILE%\.procure-ai\deploy-keys
      local-ca\                           <- %USERPROFILE%\.procure-ai\local-ca
      user-secrets\procure-ai-hosted\     <- %APPDATA%\Microsoft\UserSecrets\procure-ai-hosted
      user-secrets\procure-ai-apphost\    <- %APPDATA%\Microsoft\UserSecrets\procure-ai-apphost
      contabo-recovery-codes.txt          <- %USERPROFILE%\Downloads\contabo-recovery-codes.txt
      README.txt                          what each item is and where its original lives (written by this script)
    A mirror: a file in a copied folder that the original no longer has is deleted from the copy (named in the output). Nothing outside
    these items is touched. Then every original file is compared with each copy by SHA-256: OK, MISMATCH, MISSING, or EXTRA (in a copied
    folder only), per destination. Exit code 1 when anything is not OK. Prints names and counts only, never contents.
    Access: before copying, each destination folder gets the same ACL as %USERPROFILE%\.procure-ai (Set-CurrentUserOnlyAcl in
    common.ps1: only the current user, inheritance off at the folder, every file and subfolder inheriting that one rule), so no other
    account of the PC can read the copies; both modes then check every item under each destination and report any other identity as a
    problem. OneDrive syncs as the current user, so syncing still works. A destination inside a git repository is refused.
    The copies are plain files on purpose (Dale's decision 2026-11-08, with the risk explained: OneDrive holds them unencrypted; the
    Contabo recovery codes sit in the same folder, as Dale asked).
    Run it after any secret, key, state or DEMO PASSWORDS.txt change (procure-ai docs/hosting.md, "Backup copies and recovery").
#>
[CmdletBinding()]
param(
    # Only compare the copies with the originals; copy nothing.
    [switch] $Check,
    # The two destination folders (defaults: Dale's choice, 2026-11-08).
    [string[]] $Destination = @((Join-Path $env:USERPROFILE 'OneDrive\procure-ai secrets'), (Join-Path $env:USERPROFILE 'Documents\procure-ai secrets'))
)

. (Join-Path $PSScriptRoot '..\common.ps1')

$procure = Join-Path $env:USERPROFILE '.procure-ai'
# Copy name -> original, with what it is (the README lines).
$items = @(
    [pscustomobject]@{ Name = 'DEMO PASSWORDS.txt'; Source = $DemoPasswordsFile; What = 'all demo accounts, tokens, passwords' }
    [pscustomobject]@{ Name = 'hosted'; Source = (Join-Path $procure 'hosted'); What = 'SSH key, known_hosts, Terraform state, host.json, kubeconfig, internal CA' }
    [pscustomobject]@{ Name = 'deploy-keys'; Source = (Join-Path $procure 'deploy-keys'); What = 'Argo CD and CI deploy keys' }
    [pscustomobject]@{ Name = 'local-ca'; Source = (Join-Path $procure 'local-ca'); What = 'local cluster CA' }
    [pscustomobject]@{ Name = 'user-secrets\procure-ai-hosted'; Source = (Join-Path $env:APPDATA "Microsoft\UserSecrets\$HostedUserSecretsId"); What = 'hosted app secrets (secrets.json)' }
    [pscustomobject]@{ Name = 'user-secrets\procure-ai-apphost'; Source = (Join-Path $env:APPDATA "Microsoft\UserSecrets\$AppHostUserSecretsId"); What = 'local AppHost secrets (secrets.json)' }
    [pscustomobject]@{ Name = 'contabo-recovery-codes.txt'; Source = (Join-Path $env:USERPROFILE 'Downloads\contabo-recovery-codes.txt'); What = 'Contabo account MFA recovery codes' }
)
# Run-time files of the hosted folder: no secret, and they change while scripts run (a tunnel's PID, logs, the WAL test's working files).
function Test-Skipped([string] $relative) {
    $relative -match '^(tunnel\.pid|argocd-opened-tunnel|tfplan)$' -or $relative -like '*.log' -or $relative -match '^(run-wal-[^\\]*\.ps1|wal-run(\\.*)?)$'
}

function Get-SourceFiles($item) {
    # Relative path -> full path of every original file of an item (a single file is its own name).
    $files = [ordered]@{}
    if (Test-Path -LiteralPath $item.Source -PathType Leaf) { $files[''] = $item.Source; return $files }
    $root = (Get-Item -LiteralPath $item.Source).FullName.TrimEnd('\')
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $f.FullName.Substring($root.Length + 1)
        if ($item.Name -eq 'hosted' -and (Test-Skipped $relative)) { continue }
        $files[$relative] = $f.FullName
    }
    $files
}

function Get-Hash([string] $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

function Get-AclProblems([string] $root) {
    # Every item under $root (the folder too) that grants any identity but the current user, or a root that still inherits.
    $me = $env:USERNAME
    $found = @()
    if (-not (Get-Acl -LiteralPath $root).AreAccessRulesProtected) { $found += "$root still inherits permissions from its parent" }
    foreach ($entry in @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        $others = @((Get-Acl -LiteralPath $entry.FullName).Access | Where-Object { $_.IdentityReference.Value -notlike "*\$me" } |
            ForEach-Object { "$($_.IdentityReference.Value)" } | Sort-Object -Unique)
        if ($others) { $found += "$($entry.FullName.Substring($root.Length).TrimStart([char]92)) also grants $($others -join ', ')" }
    }
    $found
}

function Assert-NotInRepository([string] $dir) {
    # From the folder, or its nearest existing parent (checked before the folder is created).
    $start = $dir; while ($start -and -not (Test-Path -LiteralPath $start)) { $start = Split-Path $start }
    for ($d = Get-Item -LiteralPath $start -Force; $d; $d = $d.Parent) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { throw "$dir is inside the git repository $($d.FullName): never put the copies in a repo." }
    }
}

$missingSources = @($items | Where-Object { -not (Test-Path -LiteralPath $_.Source) })
if ($missingSources) { throw "Originals not found: $(($missingSources | ForEach-Object Source) -join ', '). Nothing copied." }

$problems = 0
foreach ($dest in $Destination) {
    $dest = [IO.Path]::GetFullPath($dest).TrimEnd([char]92)
    Assert-NotInRepository $dest
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        if ($Check) { Write-Host "MISSING  $dest (the folder itself)"; $problems++; continue }
        New-Item -ItemType Directory -Path $dest | Out-Null
    }
    # Current user only, before a single file is copied in (new files inherit it).
    if (-not $Check) { Set-CurrentUserOnlyAcl $dest }
    Write-Host "== $dest$(if ($Check) { ' (check only)' })"
    $ok = 0
    foreach ($item in $items) {
        $sources = Get-SourceFiles $item
        $target = Join-Path $dest $item.Name
        $isFile = $sources.Contains('')
        if (-not $Check) {
            foreach ($relative in $sources.Keys) {
                $to = if ($isFile) { $target } else { Join-Path $target $relative }
                New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
                Copy-Item -LiteralPath $sources[$relative] -Destination $to -Force
            }
        }
        # Extras: files in a copied folder that the original (after the run-time exclusions) does not have.
        if (-not $isFile -and (Test-Path -LiteralPath $target)) {
            $targetRoot = (Get-Item -LiteralPath $target).FullName.TrimEnd('\')
            foreach ($f in Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Force) {
                $relative = $f.FullName.Substring($targetRoot.Length + 1)
                if ($sources.Contains($relative)) { continue }
                if ($Check) { Write-Host "EXTRA    $($item.Name)\$relative"; $problems++ }
                else { Remove-Item -LiteralPath $f.FullName -Force; Write-Host "removed  $($item.Name)\$relative (gone from the original, or a run-time file that is not mirrored)" }
            }
        }
        foreach ($relative in $sources.Keys) {
            $copy = if ($isFile) { $target } else { Join-Path $target $relative }
            $shown = if ($isFile) { $item.Name } else { "$($item.Name)\$relative" }
            if (-not (Test-Path -LiteralPath $copy)) { Write-Host "MISSING  $shown"; $problems++; continue }
            if ((Get-Hash $sources[$relative]) -ne (Get-Hash $copy)) { Write-Host "MISMATCH $shown"; $problems++; continue }
            $ok++
        }
    }
    if (-not $Check) {
        $readme = @(
            'procure-ai secrets copy (plain files, no encryption: Dale''s decision 2026-11-08)'
            'Everything needed to manage or rebuild the procure-ai demo if the PC is lost.'
            'Originals live on the PC; this folder is a mirror written by procure-ai-gitops bootstrap/hosted/backup-hosted.ps1'
            "(last run $(Get-Date -Format 'yyyy-MM-dd HH:mm')). Run it again after any secret, key, state or DEMO PASSWORDS.txt change."
            ''
        ) + @($items | ForEach-Object {
            $original = $_.Source.Replace($env:APPDATA, '%APPDATA%').Replace($env:USERPROFILE, '%USERPROFILE%')
            '{0,-34} {1,-62} (original: {2})' -f ($_.Name + $(if (Test-Path -LiteralPath $_.Source -PathType Container) { '\' } else { '' })), $_.What, $original
        }) + @(
            ''
            'hosted\ leaves out run-time files (tunnel.pid, argocd-opened-tunnel, *.log, WAL-test scripts).'
            'Restore: copy each item back to its original location (the SSH key and the folders under %USERPROFILE%\.procure-ai keep'
            'current-user-only permissions: new-hosted-cluster.ps1 -KubeconfigOnly resets them for hosted). procure-ai'
            'docs/hosting.md, "Backup copies and recovery", has the steps, incl. new-hosted-cluster.ps1 -Import.'
        )
        Set-Content -LiteralPath (Join-Path $dest 'README.txt') -Value $readme -Encoding utf8NoBOM
    }
    Write-Host "OK       $ok files identical to their originals (SHA-256)"
    $aclProblems = @(Get-AclProblems $dest)
    foreach ($line in $aclProblems) { Write-Host "ACCESS   $line" }
    $problems += $aclProblems.Count
    if (-not $aclProblems) { Write-Host "OK       only $env:USERNAME can open the folder and everything in it" }
}
if ($problems) { Write-Host "$problems problem(s): see the lines above." -ForegroundColor Red; exit 1 }
Write-Host "Every copy matches its original in $($Destination.Count) folder(s)." -ForegroundColor Green
exit 0
