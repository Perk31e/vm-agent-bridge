# Windows PowerShell 5.1: tests encrypted-image -vp injection with dummy DPAPI data.
# No live VM or real credential is used. Cleanup removes only the dummy test directory.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:TEMP ('vab-vmware-encryption-' + [Guid]::NewGuid().ToString('N'))
$oldConfig = $env:VM_AGENT_BRIDGE_CONFIG
$oldVmrun = $env:VMRUN

function New-DummyCredential([string]$Name, [string]$Password) {
    return New-Object System.Management.Automation.PSCredential(
        $Name, (ConvertTo-SecureString $Password -AsPlainText -Force))
}

function Write-TestConfig([string]$Path, [bool]$WithImagePassword) {
    $config = @{
        backend = 'vmware'
        vm = 'C:\fake\Encrypted.vmx'
        guestOS = 'windows'
        guestWorkDir = 'C:\Users\Public\vm-agent-bridge'
        credDir = $fixture
        profiles = @{ user = @{ username = 'dummy-user'; store = 'dpapi'; ref = 'guest-user.cred' } }
    }
    if ($WithImagePassword) {
        $config.vmEncryption = @{ store = 'dpapi'; ref = 'vmware-vm-encryption.cred' }
    }
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    (New-DummyCredential 'dummy-user' 'DUMMY_GUEST_PASSWORD') |
        Export-Clixml -LiteralPath (Join-Path $fixture 'guest-user.cred')
    (New-DummyCredential 'vmware-encrypted-image' 'DUMMY_VM_IMAGE_SECRET') |
        Export-Clixml -LiteralPath (Join-Path $fixture 'vmware-vm-encryption.cred')

    $mock = Join-Path $fixture 'mock-vmrun.cmd'
    @'
@echo off
setlocal EnableDelayedExpansion
set CMDLINE=%*
if "!CMDLINE!"=="-T ws -vp DUMMY_VM_IMAGE_SECRET list" echo C:\fake\Encrypted.vmx
if "!CMDLINE!"=="-T ws list" echo C:\fake\Encrypted.vmx
echo(!CMDLINE! | C:\Windows\System32\findstr.exe /I /C:" checkToolsState " >nul
if !errorlevel!==0 echo running
echo(!CMDLINE! | C:\Windows\System32\findstr.exe /I /C:" listProcessesInGuest " >nul
if !errorlevel!==0 echo Process list: 2
echo(!CMDLINE!
'@ | Set-Content -LiteralPath $mock -Encoding ASCII
    $env:VMRUN = $mock

    $wrapper = Join-Path $PSScriptRoot '..\backends\vmware\vmrun-guest.ps1'
    foreach ($mode in @('encrypted', 'unencrypted')) {
        $env:VM_AGENT_BRIDGE_CONFIG = Join-Path $fixture ($mode + '.json')
        Write-TestConfig $env:VM_AGENT_BRIDGE_CONFIG ($mode -eq 'encrypted')

        $status = (& $wrapper status -Profile user *>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "$mode status failed with $LASTEXITCODE" }
        if ($status -notmatch 'Tools\s+:.*running') { throw "$mode tools check did not return running" }
        if ($status -notmatch 'Auth \(user\) : OK') { throw "$mode guest authentication failed" }

        $raw = (& $wrapper raw listProcessesInGuest -Profile user *>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "$mode raw call failed with $LASTEXITCODE" }
        if ($mode -eq 'encrypted') {
            if ($raw -notmatch '-T ws -vp DUMMY_VM_IMAGE_SECRET -gu dummy-user -gp DUMMY_GUEST_PASSWORD listProcessesInGuest') {
                throw 'Both -vp and -gu/-gp must be supplied for an encrypted image'
            }
        } else {
            if ($raw -match '\-vp') { throw 'Unencrypted fallback must not add -vp' }
            if ($raw -notmatch '-gu dummy-user -gp DUMMY_GUEST_PASSWORD') {
                throw 'Unencrypted fallback must retain -gu/-gp'
            }
        }
        Write-Host "PASS: $mode calling convention and guest authentication."
    }

    $parseErrors = @()
    foreach ($file in @('setup\windows\New-VmEncryptionCredential.ps1',
                        'backends\vmware\vmrun-guest.ps1', 'lib\common.ps1')) {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot "..\$file"), [ref]$null, [ref]$parseErrors)
    }
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    Write-Host 'PASS: wrapper, setup and common-library syntax.'
} finally {
    $env:VM_AGENT_BRIDGE_CONFIG = $oldConfig
    $env:VMRUN = $oldVmrun
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
