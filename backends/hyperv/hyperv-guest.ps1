<#
.SYNOPSIS
    vm-agent-bridge backend for Hyper-V using PowerShell Direct (Windows host, Windows guest).

.DESCRIPTION
    Same verbs as the other wrappers: status, push, pull, run, reboot, job, raw.
    PowerShell Direct (Invoke-Command -VMName / New-PSSession -VMName) takes a PSCredential object,
    so the password never touches a command line or a file. This is the cleanest backend.

    Requirements: run from an elevated PowerShell on the Hyper-V host; Windows guest with Hyper-V
    integration services; `vm` in config.json is the Hyper-V VM name.

    `job` here does not need the launcher dance: Invoke-Command -FilePath runs the host script in the
    guest and streams the output back. The script's exit code is taken from $LASTEXITCODE if it sets one.

.NOTES
    Status: reference implementation; not yet verified end to end.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('status', 'push', 'pull', 'run', 'reboot', 'job', 'raw')]
    [string]$Command,
    [string]$Profile = 'user',
    [switch]$NoWait,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\common.ps1')
if ($null -eq $Rest) { $Rest = @() }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'PowerShell Direct requires an elevated (Administrator) PowerShell on the Hyper-V host.'; exit 12 }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { Write-Error 'Hyper-V PowerShell module not available.'; exit 12 }

$cfg = Get-VabConfig
if ($cfg.backend -ne 'hyperv') { Write-Warning "config.json says backend '$($cfg.backend)' but you are calling the hyperv wrapper" }
$vmName = $cfg.vm

function New-GuestSession {
    $cred = Get-VabCredential $cfg $Profile
    return New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
}

switch ($Command) {

    'status' {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        Write-Host ("VM        : {0}" -f $vmName)
        Write-Host ("Power     : {0}" -f $vm.State)
        Write-Host ("Heartbeat : {0}" -f $vm.Heartbeat)
        if ($vm.State -ne 'Running') { exit 10 }
        try {
            $cred = Get-VabCredential $cfg $Profile
            $who = Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock { whoami } -ErrorAction Stop
            Write-Host ("Auth ({0}) : OK ({1})" -f $Profile, $who)
            exit 0
        } catch {
            Write-Host ("Auth ({0}) : FAILED - {1}" -f $Profile, $_.Exception.Message)
            exit 11
        }
    }

    'push' {
        if ($Rest.Count -ne 2) { throw 'usage: push <hostPath> <guestPath>' }
        $s = New-GuestSession
        try {
            $dir = Split-Path -Parent $Rest[1]
            Invoke-Command -Session $s -ScriptBlock { param($d) if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } -ArgumentList $dir
            Copy-Item -LiteralPath $Rest[0] -Destination $Rest[1] -ToSession $s -Force
            Write-Host "pushed $($Rest[0]) -> $($Rest[1])"
        } finally { Remove-PSSession $s }
        exit 0
    }

    'pull' {
        if ($Rest.Count -ne 2) { throw 'usage: pull <guestPath> <hostPath>' }
        $s = New-GuestSession
        try {
            Copy-Item -Path $Rest[0] -Destination $Rest[1] -FromSession $s -Force
            Write-Host "pulled $($Rest[0]) -> $($Rest[1])"
        } finally { Remove-PSSession $s }
        exit 0
    }

    'run' {
        if ($Rest.Count -ne 1) { throw 'usage: run <guestScriptPath> [-NoWait]' }
        $s = New-GuestSession
        try {
            $sb = {
                param($p)
                switch ([IO.Path]::GetExtension($p).ToLowerInvariant()) {
                    '.ps1' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p 2>&1; exit $LASTEXITCODE }
                    default { & cmd.exe /c $p 2>&1; exit $LASTEXITCODE }
                }
            }
            if ($NoWait) { Invoke-Command -Session $s -ScriptBlock $sb -ArgumentList $Rest[0] -AsJob | Out-Null; Write-Host 'started (no wait)'; exit 0 }
            Invoke-Command -Session $s -ScriptBlock $sb -ArgumentList $Rest[0] | ForEach-Object { Write-Host $_ }
            exit 0
        } finally { Remove-PSSession $s }
    }

    'reboot' {
        $cred = Get-VabCredential $cfg $Profile
        Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock { shutdown.exe /r /t 0 } -ErrorAction Stop
        Write-Host 'reboot requested. Poll "status" until Heartbeat is OkApplicationsHealthy again.'
        exit 0
    }

    'job' {
        if ($Rest.Count -ne 1) { throw 'usage: job <hostScript.ps1> [-Profile p]' }
        $hostScript = (Resolve-Path -LiteralPath $Rest[0]).Path
        if ([IO.Path]::GetExtension($hostScript) -ne '.ps1') { throw 'Hyper-V job runs .ps1 scripts via Invoke-Command -FilePath; wrap .cmd work in a .ps1' }
        $jobDir = Get-VabJobDir
        $hostLog = Join-Path $jobDir ([IO.Path]::GetFileNameWithoutExtension($hostScript) + '.log')
        $cred = Get-VabCredential $cfg $Profile
        $code = 0
        $out = @()
        try {
            $out = Invoke-Command -VMName $vmName -Credential $cred -FilePath $hostScript -ErrorAction Continue 2>&1 | ForEach-Object { "$_" }
        } catch { $out += "ERROR: $($_.Exception.Message)"; $code = 1 }
        ($out -join "`n") | Set-Content -LiteralPath $hostLog -Encoding UTF8
        Write-Host "---- $([IO.Path]::GetFileName($hostScript)) (host copy: $hostLog) ----"
        $out | ForEach-Object { Write-Host $_ }
        Write-Host '----'
        exit $code
    }

    'raw' {
        if ($Rest.Count -lt 1) { throw 'usage: raw <powershell command text>  (runs in the guest)' }
        $cred = Get-VabCredential $cfg $Profile
        $text = $Rest -join ' '
        Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock ([scriptblock]::Create($text)) | ForEach-Object { Write-Host $_ }
        exit 0
    }
}
