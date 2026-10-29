<#
.SYNOPSIS
    vm-agent-bridge backend for Oracle VirtualBox (VBoxManage guestcontrol), PowerShell host.

.DESCRIPTION
    Same verbs as the VMware wrapper: status, push, pull, run, reboot, job, raw.
    Requires Guest Additions running in the guest.

    Credential handling: VBoxManage accepts --passwordfile. The wrapper writes the password to a
    temporary file inside your locked-down credential directory for the duration of one call and
    deletes it afterwards, so the password never appears on a command line.

    VirtualBox copyto/copyfrom keep the source file name, so push/pull destinations must end with
    the same file name as the source (or be a directory).

.NOTES
    Status: reference implementation written against the VBoxManage 7.x manual; not yet verified end to end.
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

function Find-VBoxManage {
    if ($env:VBOXMANAGE -and (Test-Path -LiteralPath $env:VBOXMANAGE)) { return $env:VBOXMANAGE }
    $cmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in @($env:VBOX_MSI_INSTALL_PATH, $env:VBOX_INSTALL_PATH, 'C:\Program Files\Oracle\VirtualBox')) {
        if ($root) { $p = Join-Path $root 'VBoxManage.exe'; if (Test-Path -LiteralPath $p) { return $p } }
    }
    throw 'VBoxManage not found. Set $env:VBOXMANAGE to its full path.'
}

$cfg = Get-VabConfig
if ($cfg.backend -ne 'virtualbox') { Write-Warning "config.json says backend '$($cfg.backend)' but you are calling the virtualbox wrapper" }
$vm = $cfg.vm
$vbox = Find-VBoxManage

function Invoke-VBoxPlain([string[]]$Arguments) {
    $out = & $vbox @Arguments 2>&1
    $script:rc = $LASTEXITCODE
    return @($out | ForEach-Object { "$_" })
}

function Invoke-VBoxGuest([string]$Sub, [string[]]$Arguments) {
    # guestcontrol <vm> <sub> --username u --passwordfile <tmp> <args>
    $cred = Get-VabCredential $cfg $Profile
    $tmp = Join-Path $cfg.credDir (".tmp-{0}-{1}.passwordfile" -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [IO.File]::WriteAllText($tmp, $cred.GetNetworkCredential().Password, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $vbox 'guestcontrol' $vm $Sub '--username' $cred.UserName '--passwordfile' $tmp @Arguments 2>&1
        $script:rc = $LASTEXITCODE
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    return @($out | ForEach-Object { "$_" })
}

function Fail([string]$What, [string[]]$Output) {
    $text = ($Output -join "`n").Trim()
    Write-Error "$What failed (VBoxManage exit $script:rc)$(if ($text) { ": $text" })"
    $code = 1
    if ($script:rc) { $code = $script:rc }
    exit $code
}

function Get-RunArgs([string]$GuestScript) {
    if ($cfg.guestOS -eq 'windows') { return @('--exe', 'C:\Windows\System32\cmd.exe', '--', 'cmd.exe', '/c', $GuestScript) }
    return @('--exe', '/bin/sh', '--', 'sh', $GuestScript)
}

function Split-Dest([string]$Source, [string]$Dest) {
    # VBoxManage keeps the file name; return the directory part of $Dest, validating the leaf.
    $srcLeaf = [IO.Path]::GetFileName($Source)
    $destLeaf = if ($cfg.guestOS -eq 'windows') { $Dest.Split('\')[-1] } else { $Dest.Split('/')[-1] }
    if ($destLeaf -eq $srcLeaf) {
        $dir = $Dest.Substring(0, $Dest.Length - $destLeaf.Length).TrimEnd('\', '/')
        return $dir
    }
    if (-not [IO.Path]::HasExtension($destLeaf)) { return $Dest }  # treat as directory
    throw "VirtualBox copies keep the file name; destination must end with '$srcLeaf' or be a directory (got '$Dest')"
}

switch ($Command) {

    'status' {
        $info = Invoke-VBoxPlain @('showvminfo', $vm, '--machinereadable')
        if ($script:rc -ne 0) { Fail "showvminfo $vm" $info }
        $state = ($info | Where-Object { $_ -like 'VMState=*' }) -replace '^VMState=', '' -replace '"', ''
        $ga = ($info | Where-Object { $_ -like 'GuestAdditionsRunLevel=*' }) -replace '^GuestAdditionsRunLevel=', ''
        Write-Host ("VM        : {0}" -f $vm)
        Write-Host ("Power     : {0}" -f $state)
        Write-Host ("Additions : run level {0} (2 = userland ready, 3 = desktop)" -f $ga)
        if ($state -ne 'running') { exit 10 }
        $who = if ($cfg.guestOS -eq 'windows') { @('--exe', 'C:\Windows\System32\whoami.exe', '--wait-stdout', '--', 'whoami') } else { @('--exe', '/usr/bin/id', '--wait-stdout', '--', 'id', '-un') }
        $out = Invoke-VBoxGuest 'run' $who
        if ($script:rc -ne 0) { Write-Host ("Auth ({0}) : FAILED - {1}" -f $Profile, (($out -join ' ').Trim())); exit 11 }
        Write-Host ("Auth ({0}) : OK ({1})" -f $Profile, (($out -join ' ').Trim()))
        exit 0
    }

    'push' {
        if ($Rest.Count -ne 2) { throw 'usage: push <hostPath> <guestPath>' }
        $hostPath = (Resolve-Path -LiteralPath $Rest[0]).Path
        $dir = Split-Dest $hostPath $Rest[1]
        Invoke-VBoxGuest 'mkdir' @('--parents', $dir) | Out-Null
        $out = Invoke-VBoxGuest 'copyto' @('--target-directory', $dir, $hostPath)
        if ($script:rc -ne 0) { Fail "push $hostPath -> $dir" $out }
        Write-Host "pushed $hostPath -> $dir"
        exit 0
    }

    'pull' {
        if ($Rest.Count -ne 2) { throw 'usage: pull <guestPath> <hostPath>' }
        $hostDest = [IO.Path]::GetFullPath($Rest[1])
        $dir = if ([IO.Path]::GetFileName($hostDest) -eq ($Rest[0].Split('\', '/')[-1])) { Split-Path -Parent $hostDest } else { $hostDest }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $out = Invoke-VBoxGuest 'copyfrom' @('--target-directory', $dir, $Rest[0])
        if ($script:rc -ne 0) { Fail "pull $($Rest[0]) -> $dir" $out }
        Write-Host "pulled $($Rest[0]) -> $dir"
        exit 0
    }

    'run' {
        if ($Rest.Count -ne 1) { throw 'usage: run <guestScriptPath> [-NoWait]' }
        $runArgs = Get-RunArgs $Rest[0]
        if (-not $NoWait) { $runArgs = @('--wait-stdout', '--wait-stderr') + $runArgs }
        $out = Invoke-VBoxGuest 'run' $runArgs
        if ($out) { $out | ForEach-Object { Write-Host $_ } }
        exit $script:rc
    }

    'reboot' {
        $rebootArgs = if ($cfg.guestOS -eq 'windows') { @('--exe', 'C:\Windows\System32\shutdown.exe', '--', 'shutdown', '/r', '/t', '0') } else { @('--exe', '/bin/sh', '--', 'sh', '-c', 'systemctl reboot || reboot') }
        $out = Invoke-VBoxGuest 'run' $rebootArgs
        if ($script:rc -ne 0) { Fail 'reboot' $out }
        Write-Host 'reboot requested. Poll "status" until Additions run level is back to 2 or 3.'
        exit 0
    }

    'job' {
        if ($Rest.Count -ne 1) { throw 'usage: job <hostScript> [-Profile p]' }
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

        Invoke-VBoxGuest 'mkdir' @('--parents', $cfg.guestWorkDir) | Out-Null
        Write-VabTextFile $hostLauncher (New-VabLauncherText $cfg $guestScript $guestLog) -Unix:($cfg.guestOS -ne 'windows')
        $out = Invoke-VBoxGuest 'copyto' @('--target-directory', $cfg.guestWorkDir, $hostScript, $hostLauncher)
        if ($script:rc -ne 0) { Fail 'push job files' $out }
        $out = Invoke-VBoxGuest 'run' (@('--wait-stdout', '--wait-stderr') + (Get-RunArgs $guestLauncher))
        if (Test-Path -LiteralPath $hostLog) { Remove-Item -LiteralPath $hostLog -Force }
        $out = Invoke-VBoxGuest 'copyfrom' @('--target-directory', $jobDir, $guestLog)
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
        if ($Rest.Count -lt 1) { throw 'usage: raw <guestcontrol-subcommand> [args...]' }
        $out = Invoke-VBoxGuest $Rest[0] $(if ($Rest.Count -gt 1) { $Rest[1..($Rest.Count - 1)] } else { @() })
        if ($out) { $out | ForEach-Object { Write-Host $_ } }
        exit $script:rc
    }
}
