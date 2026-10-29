# Shared helpers for the vm-agent-bridge PowerShell backends. Dot-source this file.
# Nothing in here prints a password. Keep it that way.

Set-StrictMode -Version 2.0

function Get-VabConfigPath {
    if ($env:VM_AGENT_BRIDGE_CONFIG) { return $env:VM_AGENT_BRIDGE_CONFIG }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'vm-agent-bridge\config.json') }
    return (Join-Path $HOME '.config/vm-agent-bridge/config.json')
}

function Get-VabConfig {
    $path = Get-VabConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "vm-agent-bridge config not found at '$path'. The user must run setup/windows/New-GuestCredential.ps1 first."
    }
    $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($k in 'backend', 'vm', 'credDir', 'profiles') {
        if (-not ($cfg.PSObject.Properties.Name -contains $k)) { throw "config '$path' is missing the '$k' field" }
    }
    if (-not ($cfg.PSObject.Properties.Name -contains 'guestOS')) {
        $cfg | Add-Member -NotePropertyName guestOS -NotePropertyValue 'windows'
    }
    if (-not ($cfg.PSObject.Properties.Name -contains 'guestWorkDir')) {
        $default = if ($cfg.guestOS -eq 'windows') { 'C:\Users\Public\vm-agent-bridge' } else { '/tmp/vm-agent-bridge' }
        $cfg | Add-Member -NotePropertyName guestWorkDir -NotePropertyValue $default
    }
    $cfg | Add-Member -NotePropertyName _path -NotePropertyValue $path -Force
    return $cfg
}

function Get-VabProfile($cfg, [string]$Name) {
    $p = $cfg.profiles.PSObject.Properties[$Name]
    if (-not $p) {
        $defined = ($cfg.profiles.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
        throw "Profile '$Name' is not defined in $($cfg._path). Defined profiles: $defined"
    }
    return $p.Value
}

function Get-VabCredential($cfg, [string]$ProfileName) {
    # Returns a PSCredential. Callers must never write its password to output.
    $p = Get-VabProfile $cfg $ProfileName
    switch ($p.store) {
        'dpapi' {
            $file = Join-Path $cfg.credDir $p.ref
            if (-not (Test-Path -LiteralPath $file)) {
                throw "Credential file for profile '$ProfileName' does not exist ($file). The user must create it: setup/windows/New-GuestCredential.ps1 -Profile $ProfileName"
            }
            $cred = Import-Clixml -LiteralPath $file
            if ($cred -isnot [System.Management.Automation.PSCredential]) { throw "'$file' does not contain a PSCredential" }
            return $cred
        }
        default { throw "Credential store '$($p.store)' is not supported by the PowerShell backends. Use 'dpapi'." }
    }
}

function Get-VabGuestPath($cfg, [string]$Leaf) {
    if ($cfg.guestOS -eq 'windows') { return ($cfg.guestWorkDir.TrimEnd('\') + '\' + $Leaf) }
    return ($cfg.guestWorkDir.TrimEnd('/') + '/' + $Leaf)
}

function Get-VabJobDir {
    # Host-side folder for generated launchers and pulled logs. Kept short on purpose:
    # long host paths make hypervisor file copies fail.
    $d = Join-Path (Split-Path -Parent (Get-VabConfigPath)) 'jobs'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function New-VabLauncherText($cfg, [string]$GuestScript, [string]$GuestLog) {
    # Text of a tiny launcher that runs $GuestScript inside the guest, sends stdout+stderr
    # to $GuestLog and appends "RC=<exit code>". Windows: .cmd; Linux: .sh
    if ($cfg.guestOS -eq 'windows') {
        $ext = [IO.Path]::GetExtension($GuestScript).ToLowerInvariant()
        switch ($ext) {
            '.ps1' { $inner = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$GuestScript`"" }
            '.cmd' { $inner = "call `"$GuestScript`"" }
            '.bat' { $inner = "call `"$GuestScript`"" }
            default { throw "Unsupported guest script extension '$ext' for a Windows guest (use .ps1, .cmd or .bat)" }
        }
        # Note the space before >>: "RC=0>>" would be parsed by cmd as a handle redirect.
        return "@echo off`r`n$inner > `"$GuestLog`" 2>&1`r`necho RC=%ERRORLEVEL% >> `"$GuestLog`"`r`n"
    }
    return "#!/bin/sh`n/bin/sh '$GuestScript' > '$GuestLog' 2>&1`necho RC=`$? >> '$GuestLog'`n"
}

function Write-VabTextFile([string]$Path, [string]$Content, [switch]$Unix) {
    $enc = if ($Unix) { New-Object System.Text.UTF8Encoding($false) } else { [System.Text.Encoding]::ASCII }
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Get-VabExitCodeFromLog([string]$LogText) {
    if ($LogText -match '(?m)^RC=(-?\d+)\s*$') { return [int]$Matches[1] }
    return $null
}

function Get-VabLauncherExtension($cfg) {
    if ($cfg.guestOS -eq 'windows') { return '.launcher.cmd' }
    return '.launcher.sh'
}
