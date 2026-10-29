# Example guest job (Windows guest): which NICs exist, which one did the kernel debugger (KDNET) take,
# what are the IPs. Everything goes to stdout; the launcher captures it.
# Run from the host:  <wrapper> job .\examples\collect-nic-info.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

"=== whoami ==="
whoami

"=== Adapters (including hidden) ==="
Get-NetAdapter -IncludeHidden | Format-Table Name, InterfaceDescription, Status, MacAddress, ifIndex -AutoSize | Out-String -Width 200

"=== IPv4 ==="
Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize | Out-String -Width 200

"=== PnP network devices with PCI location (a NIC in 'Error'/'Not Present' is often the one KDNET owns) ==="
Get-PnpDevice -Class Net | ForEach-Object {
    $loc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationInfo -ErrorAction SilentlyContinue).Data
    "{0} | {1} | {2}" -f $_.FriendlyName, $_.Status, $loc
}

"=== Kernel debug settings (needs admin; harmless failure otherwise) ==="
cmd /c "bcdedit /dbgsettings 2>&1"

"=== kdnic service ==="
Get-Service -Name kdnic -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize | Out-String
