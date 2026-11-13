<#
.SYNOPSIS
    Store a VMware encrypted-image password separately from the guest account.
    RUN THIS YOURSELF, never through an AI agent.

.DESCRIPTION
    Reads the VMware encryption password into a SecureString, stores it with DPAPI in
    the already-protected vm-agent-bridge credential directory, and updates only the
    non-secret vmEncryption reference in config.json. The VMware wrapper then injects
    this credential as -vp into every vmrun call, avoiding an interactive password
    prompt that would otherwise block checkToolsState and guest jobs.

.EXAMPLE
    .\New-VmEncryptionCredential.ps1 -Profile client01
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')][string]$Profile = 'user',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\common.ps1')

$cfg = Get-VabConfig
if ($cfg.backend -ne 'vmware') { throw "Configured backend is '$($cfg.backend)', not vmware." }
if (-not (Get-Command Get-Credential -ErrorAction SilentlyContinue)) {
    throw 'This setup requires Windows PowerShell / PowerShell with DPAPI support.'
}
$credDir = [IO.Path]::GetFullPath($cfg.credDir)
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$owner = (Get-Acl -LiteralPath $credDir).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
if ($owner -ne $me.User.Value) {
    throw "Credential directory '$credDir' is owned by $owner rather than $($me.Name). Run New-GuestCredential.ps1 first or fix its ownership."
}

$secure = Read-Host 'Encrypted virtual machine password (not the GUEST password)' -AsSecureString
if ($secure.Length -eq 0) { throw 'Empty password; no credential was stored.' }
$securePath = Join-Path $credDir 'vmware-vm-encryption.cred'
$wrapped = New-Object System.Management.Automation.PSCredential('vmware-encrypted-image', $secure)
$wrapped | Export-Clixml -LiteralPath $securePath

# Match New-GuestCredential.ps1: no inherited permissions, only this user and SYSTEM.
$inherit = ''
$args = @("`"$securePath`"", '/inheritance:r', '/grant:r', "*$($me.User.Value):${inherit}F",
          '/grant:r', "*S-1-5-18:${inherit}F", '/q')
$out = & icacls.exe @args 2>&1
if ($LASTEXITCODE -ne 0) { throw "icacls failed on '$securePath': $out" }
Write-Host "Stored VMware encrypted-image credential in $securePath"

$cfg | Add-Member -NotePropertyName vmEncryption -NotePropertyValue ([pscustomobject]@{
    store = 'dpapi'
    ref = 'vmware-vm-encryption.cred'
}) -Force
$cfg.PSObject.Properties.Remove('_path')
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-VabConfigPath) -Encoding UTF8
Write-Host "Updated config $(Get-VabConfigPath) (no secrets inside)"
Write-Host 'The VMware wrapper will now supply -vp as well as the guest -gu/-gp credential.'

if ($SkipVerify) { exit 0 }
$wrapper = Join-Path ((Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path) 'backends\vmware\vmrun-guest.ps1'
Write-Host ''
Write-Host "Verifying with: $wrapper raw checkToolsState -Profile $Profile" -ForegroundColor Cyan
& $wrapper raw checkToolsState -Profile $Profile
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Credential was stored, but verification failed. Check the VM encryption password, power state and VMware Tools.'
    exit 3
}
Write-Host 'Done. Encrypted-VM and guest credentials are both usable.' -ForegroundColor Green
