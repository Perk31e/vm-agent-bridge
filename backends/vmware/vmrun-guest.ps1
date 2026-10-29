<#
.SYNOPSIS
    vm-agent-bridge backend for VMware Workstation / Fusion / Player (vmrun), PowerShell host.

.DESCRIPTION
    Verbs:
      status  [-Profile p]              VM running? tools running? credential authenticates?
      push    <hostPath> <guestPath>    copy a file into the guest
      pull    <guestPath> <hostPath>    copy a file out of the guest
      run     <guestScript> [-NoWait]   run a .cmd/.bat/.ps1 (Windows guest) or .sh (Linux guest) already in the guest
      reboot                            graceful restart through VMware Tools (no credential needed)
      job     <hostScript> [-Profile p] push + launcher + run + pull log + print log; exit code = script's RC
      raw     <vmrunCommand> [args...]  pass-through; credential and vmx path are injected after the command

    The guest password is read from the DPAPI file named in config.json and handed to vmrun on its
    command line (that is the only interface vmrun has). It is never printed.

.NOTES
    Verified on: Windows 11 host, VMware Workstation 17/26, Windows 11 guest, non-admin and admin guest accounts.
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

function Find-Vmrun {
    if ($env:VMRUN -and (Test-Path -LiteralPath $env:VMRUN)) { return $env:VMRUN }
    $cmd = Get-Command vmrun -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        'C:\Program Files\VMware\VMware Workstation\vmrun.exe',
        'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe',
        'C:\Program Files (x86)\VMware\VMware Player\vmrun.exe',
        '/Applications/VMware Fusion.app/Contents/Public/vmrun',
        '/usr/bin/vmrun'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'vmrun not found. Set $env:VMRUN to its full path.'
}

$cfg = Get-VabConfig
if ($cfg.backend -ne 'vmware') { Write-Warning "config.json says backend '$($cfg.backend)' but you are calling the vmware wrapper" }
$vmx = $cfg.vm
$vmrun = Find-Vmrun
# $IsMacOS only exists on PowerShell 6+; Windows PowerShell 5.1 runs under Set-StrictMode here.
$hostType = if ((Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS) { 'fusion' } else { 'ws' }

function Invoke-VmrunPlain([string[]]$Arguments) {
    # No credential. Returns output lines; sets $script:rc.
    $out = & $vmrun -T $hostType @Arguments 2>&1
    $script:rc = $LASTEXITCODE
    return @($out | ForEach-Object { "$_" })
}

function Invoke-VmrunAuth([string[]]$Arguments) {
    # With credential. The password variable lives only inside this function.
    $cred = Get-VabCredential $cfg $Profile
    $pw = $cred.GetNetworkCredential().Password
    try {
        $out = & $vmrun -T $hostType -gu $cred.UserName -gp $pw @Arguments 2>&1
        $script:rc = $LASTEXITCODE
    } finally {
        $pw = $null
    }
    return @($out | ForEach-Object { "$_" })
}

function Fail([string]$What, [string[]]$Output) {
    $text = ($Output -join "`n").Trim()
    Write-Error "$What failed (vmrun exit $script:rc)$(if ($text) { ": $text" })"
    $code = 1
    if ($script:rc) { $code = $script:rc }
    exit $code
}

function Ensure-GuestWorkDir {
    $out = Invoke-VmrunAuth @('directoryExistsInGuest', $vmx, $cfg.guestWorkDir)
    if (($out -join ' ') -match 'The directory exists') { return }
    $out = Invoke-VmrunAuth @('createDirectoryInGuest', $vmx, $cfg.guestWorkDir)
    if ($script:rc -ne 0 -and -not (($out -join ' ') -match 'already exists')) { Fail "createDirectoryInGuest $($cfg.guestWorkDir)" $out }
}

function Get-GuestInterpreterArgs([string]$GuestScript) {
    if ($cfg.guestOS -eq 'windows') {
        if ($GuestScript -match '\s') { throw "Guest script path must not contain spaces ('$GuestScript'); vmrun mangles quoted arguments." }
        return @('C:\Windows\System32\cmd.exe', "/c $GuestScript")
    }
    return @('/bin/sh', $GuestScript)
}

switch ($Command) {

    'status' {
        $running = Invoke-VmrunPlain @('list')
        $isRunning = @($running | Where-Object { $_ -ieq $vmx }).Count -gt 0
        Write-Host ("VM        : {0}" -f $vmx)
        Write-Host ("Power     : {0}" -f $(if ($isRunning) { 'running' } else { 'not running' }))
        if (-not $isRunning) { exit 10 }
        $tools = Invoke-VmrunPlain @('checkToolsState', $vmx)
        Write-Host ("Tools     : {0}" -f (($tools -join ' ').Trim()))
        $procs = Invoke-VmrunAuth @('listProcessesInGuest', $vmx)
        if ($script:rc -ne 0) {
            Write-Host ("Auth ({0}) : FAILED - {1}" -f $Profile, (($procs -join ' ').Trim()))
            exit 11
        }
        $count = ($procs | Select-Object -First 1)
        Write-Host ("Auth ({0}) : OK ({1})" -f $Profile, $count)
        exit 0
    }

    'push' {
        if ($Rest.Count -ne 2) { throw 'usage: push <hostPath> <guestPath>' }
        $hostPath = (Resolve-Path -LiteralPath $Rest[0]).Path
        if ($hostPath.Length -gt 200) { Write-Warning 'Host path is very long; vmrun copies have been seen to fail on long paths.' }
        $out = Invoke-VmrunAuth @('copyFileFromHostToGuest', $vmx, $hostPath, $Rest[1])
        if ($script:rc -ne 0) { Fail "push $hostPath -> $($Rest[1])" $out }
        Write-Host "pushed $hostPath -> $($Rest[1])"
        exit 0
    }

    'pull' {
        if ($Rest.Count -ne 2) { throw 'usage: pull <guestPath> <hostPath>' }
        $hostPath = [IO.Path]::GetFullPath($Rest[1])
        $out = Invoke-VmrunAuth @('copyFileFromGuestToHost', $vmx, $Rest[0], $hostPath)
        if ($script:rc -ne 0) { Fail "pull $($Rest[0]) -> $hostPath" $out }
        Write-Host "pulled $($Rest[0]) -> $hostPath"
        exit 0
    }

    'run' {
        if ($Rest.Count -ne 1) { throw 'usage: run <guestScriptPath> [-NoWait]' }
        $interp = Get-GuestInterpreterArgs $Rest[0]
        $vmArgs = @('runProgramInGuest', $vmx)
        if ($NoWait) { $vmArgs += '-noWait' }
        $vmArgs += $interp
        $out = Invoke-VmrunAuth $vmArgs
        if ($script:rc -ne 0) { Fail "run $($Rest[0])" $out }
        if ($out) { $out | ForEach-Object { Write-Host $_ } }
        exit 0
    }

    'reboot' {
        $out = Invoke-VmrunPlain @('reset', $vmx, 'soft')
        if ($script:rc -ne 0) { Fail 'reboot (reset soft)' $out }
        Write-Host 'reboot requested (graceful, via VMware Tools). Poll "status" until Tools is running again.'
        exit 0
    }

    'job' {
        if ($Rest.Count -ne 1) { throw 'usage: job <hostScript.ps1|.cmd|.bat|.sh> [-Profile p]' }
        $hostScript = (Resolve-Path -LiteralPath $Rest[0]).Path
        $leaf = [IO.Path]::GetFileName($hostScript)
        if ($leaf -match '\s') { throw "Script file name must not contain spaces ('$leaf')" }
        $base = [IO.Path]::GetFileNameWithoutExtension($hostScript)
        $jobDir = Get-VabJobDir

        $guestScript = Get-VabGuestPath $cfg $leaf
        $guestLauncher = Get-VabGuestPath $cfg ($base + (Get-VabLauncherExtension $cfg))
        $guestLog = Get-VabGuestPath $cfg "$base.log"
        $hostLauncher = Join-Path $jobDir ($base + (Get-VabLauncherExtension $cfg))
        $hostLog = Join-Path $jobDir "$base.log"

        Ensure-GuestWorkDir
        Write-VabTextFile $hostLauncher (New-VabLauncherText $cfg $guestScript $guestLog) -Unix:($cfg.guestOS -ne 'windows')

        $out = Invoke-VmrunAuth @('copyFileFromHostToGuest', $vmx, $hostScript, $guestScript)
        if ($script:rc -ne 0) { Fail "push $hostScript" $out }
        $out = Invoke-VmrunAuth @('copyFileFromHostToGuest', $vmx, $hostLauncher, $guestLauncher)
        if ($script:rc -ne 0) { Fail "push $hostLauncher" $out }

        $interp = Get-GuestInterpreterArgs $guestLauncher
        $out = Invoke-VmrunAuth (@('runProgramInGuest', $vmx) + $interp)
        if ($script:rc -ne 0) { Fail "run $guestLauncher" $out }

        if (Test-Path -LiteralPath $hostLog) { Remove-Item -LiteralPath $hostLog -Force }
        $out = Invoke-VmrunAuth @('copyFileFromGuestToHost', $vmx, $guestLog, $hostLog)
        if ($script:rc -ne 0) { Fail "pull $guestLog" $out }

        $log = Get-Content -LiteralPath $hostLog -Raw -Encoding UTF8
        Write-Host "---- $leaf (guest log: $guestLog, host copy: $hostLog) ----"
        Write-Host $log.TrimEnd()
        Write-Host '----'
        $code = Get-VabExitCodeFromLog $log
        if ($null -eq $code) { Write-Warning 'No RC= line in log; the launcher did not finish normally.'; exit 1 }
        exit $code
    }

    'raw' {
        if ($Rest.Count -lt 1) { throw 'usage: raw <vmrunCommand> [args...]  (vmx path is inserted after the command)' }
        $vmArgs = @($Rest[0], $vmx)
        if ($Rest.Count -gt 1) { $vmArgs += $Rest[1..($Rest.Count - 1)] }
        $out = Invoke-VmrunAuth $vmArgs
        if ($out) { $out | ForEach-Object { Write-Host $_ } }
        exit $script:rc
    }
}
