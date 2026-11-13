<#
.SYNOPSIS
    Store a guest VM credential for vm-agent-bridge. RUN THIS YOURSELF, never through an AI agent.

.DESCRIPTION
    1. Asks where to keep credentials (or takes -CredDir) and validates the directory:
       absolute, local (no UNC), not inside a Git repository, not inside a cloud-synced folder,
       not under TEMP, owned by you. Creates it if missing and strips inherited permissions so
       only you and SYSTEM can read it.
    2. Pops the standard Windows credential dialog (Get-Credential) and stores the result with
       Export-Clixml. The password is encrypted with DPAPI for your account on this machine only.
    3. Writes/updates the non-secret config.json (backend, VM, cred dir, profile -> username/ref).
    4. Verifies the stored credential with one harmless guest call through the backend wrapper.

.EXAMPLE
    .\New-GuestCredential.ps1 -Backend vmware -Vm "C:\VMs\Win11\Win11.vmx" -Profile user
    .\New-GuestCredential.ps1 -Backend vmware -Vm "C:\VMs\Win11\Win11.vmx" -Profile admin
    .\New-GuestCredential.ps1 -Backend hyperv -Vm "Win11-Lab" -Profile admin -CredDir D:\secure\vab
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('vmware', 'virtualbox', 'hyperv')][string]$Backend,
    [Parameter(Mandatory = $true)][string]$Vm,
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')][string]$Profile = 'user',
    [string]$CredDir,
    [ValidateSet('windows', 'linux')][string]$GuestOS = 'windows',
    [string]$GuestWorkDir,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\common.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$mySid = $me.User.Value
$recommended = Join-Path $env:LOCALAPPDATA 'vm-agent-bridge\creds'

function Test-UnderPath([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $p = $Path.TrimEnd('\') + '\'
    $r = $Root.TrimEnd('\') + '\'
    return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CredDirProblems([string]$Dir) {
    $problems = @()
    if (-not [IO.Path]::IsPathRooted($Dir)) { $problems += 'must be an absolute path' }
    if ($Dir.StartsWith('\\')) { $problems += 'must be a local path, not a network share (UNC)' }

    # Inside a Git repository? (any parent with a .git entry)
    $cur = $Dir
    while ($cur) {
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { $problems += "is inside a Git repository ($cur). Credentials must never live in a repo."; break }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    if (Test-UnderPath $Dir $repoRoot) { $problems += 'is inside the vm-agent-bridge checkout' }

    # Cloud-synced folders
    foreach ($root in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if (Test-UnderPath $Dir $root) { $problems += "is inside OneDrive ($root); synced folders leak credentials to other devices" }
    }
    if ($Dir -match '\\(OneDrive[^\\]*|Dropbox|Google Drive|GoogleDrive|iCloudDrive|Box)(\\|$)') { $problems += 'looks like a cloud-synced folder (OneDrive/Dropbox/Google Drive/iCloud/Box)' }

    foreach ($root in @($env:TEMP, $env:TMP, 'C:\Windows\Temp')) {
        if (Test-UnderPath $Dir $root) { $problems += 'is inside a TEMP folder' }
    }
    if (Test-UnderPath $Dir (Get-Location).Path -and -not (Test-UnderPath $Dir $env:LOCALAPPDATA)) {
        $problems += 'is inside the current working directory; pick a dedicated location outside your project'
    }

    if (Test-Path -LiteralPath $Dir) {
        if (-not (Get-Item -LiteralPath $Dir).PSIsContainer) { $problems += 'exists but is a file' }
        else {
            $owner = (Get-Acl -LiteralPath $Dir).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne $mySid) {
                $problems += "is owned by $owner, not by you ($($me.Name)); if the directory is yours, run: icacls `"$Dir`" /setowner `"$($me.Name)`""
            }
        }
    }
    return $problems
}

function Lock-Acl([string]$Path, [bool]$IsDir) {
    $inherit = if ($IsDir) { '(OI)(CI)' } else { '' }
    $icaclsArgs = @("`"$Path`"", '/inheritance:r', '/grant:r', "*${mySid}:${inherit}F", '/grant:r', "*S-1-5-18:${inherit}F", '/q')
    $out = & icacls.exe @icaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on '$Path': $out" }
}

function Set-PathOwner([string]$Path) {
    # An elevated shell creates new objects owned by BUILTIN\Administrators, not by the user.
    # The credential directory/file must be owned by the user, so claim ownership explicitly.
    $out = & icacls.exe "`"$Path`"" /setowner "*$mySid" /q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed on '$Path': $out" }
}

function Repair-ElevatedOwner([string]$Path) {
    # A directory created by an earlier elevated run is owned by BUILTIN\Administrators, which
    # makes the next profile setup fail the "owned by you" check. If the ACL already grants this
    # user FullControl, take ownership back instead of making the user repair it by hand.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Get-Item -LiteralPath $Path).PSIsContainer) { return }
    $ownerSid = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -ne 'S-1-5-32-544') { return }
    $acl = Get-Acl -LiteralPath $Path
    $mine = $acl.Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        ($_.IdentityReference.Value -eq $mySid -or $_.IdentityReference.Value -eq $me.Name) -and
        (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl)
    }
    if (-not $mine) { return }
    Write-Host "Note: '$Path' is owned by BUILTIN\Administrators (it was created from an elevated shell)." -ForegroundColor Yellow
    Write-Host "      Taking ownership as $($me.Name); the ACL already grants only you and SYSTEM." -ForegroundColor Yellow
    & icacls.exe "`"$Path`"" /setowner "*$mySid" /q | Out-Null
}

# ---- 1. credential directory ------------------------------------------------------------
Write-Host ''
Write-Host 'vm-agent-bridge credential setup' -ForegroundColor Cyan
Write-Host "  Backend : $Backend"
Write-Host "  VM      : $Vm"
Write-Host "  Profile : $Profile"
Write-Host ''

if (-not $CredDir) {
    Write-Host 'Where should credential files live? They are DPAPI-encrypted for your account, but the'
    Write-Host 'directory still must be yours alone: not in a repo, not in a synced folder, not in TEMP.'
    Write-Host "Recommended: $recommended"
    $answer = Read-Host "Credential directory [Enter = recommended]"
    $CredDir = if ([string]::IsNullOrWhiteSpace($answer)) { $recommended } else { $answer.Trim('"').Trim() }
}
if (-not [IO.Path]::IsPathRooted($CredDir)) {
    Write-Host "Refusing credential directory '$CredDir': must be an absolute path (got a relative one)." -ForegroundColor Red
    exit 2
}
$CredDir = [IO.Path]::GetFullPath($CredDir)

Repair-ElevatedOwner $CredDir

$problems = @(Get-CredDirProblems $CredDir | Select-Object -Unique)
if ($problems.Count -gt 0) {
    Write-Host "Refusing credential directory '$CredDir':" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 2
}

if (-not (Test-Path -LiteralPath $CredDir)) {
    New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
    Set-PathOwner $CredDir
    Write-Host "Created $CredDir"
}
Lock-Acl $CredDir $true
Write-Host "Locked ACL on $CredDir (only $($me.Name) and SYSTEM)"

# ---- 2. credential ------------------------------------------------------------------------
$credFile = Join-Path $CredDir "guest-$Profile.cred"
if (Test-Path -LiteralPath $credFile) { Write-Host "Replacing existing $credFile" -ForegroundColor Yellow }

$cred = Get-Credential -Message "Guest account for '$Vm' (profile '$Profile'). Enter the GUEST user name and password."
if (-not $cred) { Write-Host 'Cancelled.'; exit 1 }
if ([string]::IsNullOrWhiteSpace($cred.UserName)) { Write-Host 'Empty user name; aborting.' -ForegroundColor Red; exit 1 }

$cred | Export-Clixml -LiteralPath $credFile
Lock-Acl $credFile $false
Set-PathOwner $credFile
Write-Host "Stored credential for guest user '$($cred.UserName)' in $credFile"

# ---- 3. config.json -----------------------------------------------------------------------
$cfgPath = Get-VabConfigPath
$cfgDir = Split-Path -Parent $cfgPath
if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

if (Test-Path -LiteralPath $cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    if ($cfg.credDir -and $cfg.credDir -ne $CredDir) {
        Write-Host "Note: config previously pointed at '$($cfg.credDir)'; other profiles stored there will no longer resolve." -ForegroundColor Yellow
    }
} else {
    $cfg = [pscustomobject]@{ profiles = [pscustomobject]@{} }
}
foreach ($pair in @{ backend = $Backend; vm = $Vm; guestOS = $GuestOS; credDir = $CredDir }.GetEnumerator()) {
    $cfg | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value -Force
}
if ($GuestWorkDir) { $cfg | Add-Member -NotePropertyName guestWorkDir -NotePropertyValue $GuestWorkDir -Force }
elseif (-not ($cfg.PSObject.Properties.Name -contains 'guestWorkDir')) {
    $cfg | Add-Member -NotePropertyName guestWorkDir -NotePropertyValue $(if ($GuestOS -eq 'windows') { 'C:\Users\Public\vm-agent-bridge' } else { '/tmp/vm-agent-bridge' })
}
if (-not ($cfg.PSObject.Properties.Name -contains 'profiles')) { $cfg | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) }
$cfg.profiles | Add-Member -NotePropertyName $Profile -NotePropertyValue ([pscustomobject]@{
    username = $cred.UserName; store = 'dpapi'; ref = "guest-$Profile.cred" }) -Force

$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
Write-Host "Wrote config $cfgPath (no secrets inside)"

# ---- 4. verify ----------------------------------------------------------------------------
if ($SkipVerify) { Write-Host 'Skipping verification (-SkipVerify).'; exit 0 }

$wrapper = switch ($Backend) {
    'vmware'     { Join-Path $repoRoot 'backends\vmware\vmrun-guest.ps1' }
    'virtualbox' { Join-Path $repoRoot 'backends\virtualbox\vbox-guest.ps1' }
    'hyperv'     { Join-Path $repoRoot 'backends\hyperv\hyperv-guest.ps1' }
}
Write-Host ''
Write-Host "Verifying with: $wrapper status -Profile $Profile" -ForegroundColor Cyan
& $wrapper status -Profile $Profile
if ($LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host 'Done. The agent can now use the wrapper; it never needs the password.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Credential stored, but verification FAILED. Common causes: wrong guest user name or password,' -ForegroundColor Yellow
    Write-Host 'guest tools/agent not running, VM powered off. Fix and re-run this script to replace the credential.' -ForegroundColor Yellow
    exit 3
}
