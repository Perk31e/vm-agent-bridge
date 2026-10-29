# Case study: the KDNET connection that would not come up

This is the session that produced vm-agent-bridge. It is kept here because it shows both why an
agent needs guest access and how the credential pattern fell out of a real constraint.

## Setup

- Host: Windows 11, VMware Workstation, `kd.exe` from the Windows SDK debuggers running in a
  Windows Terminal tab as `kd -k net:port=50000,key=<key>`.
- Guest: a hardened Windows 11 VM with **two** e1000e NICs: one NAT (host side 192.168.155.1),
  one host-only (host side 192.168.14.1).
- Symptom: `kd` sat at `Waiting to reconnect...` forever. A previous agent had been unable to
  fix it.

## What the host could tell us (no guest access yet)

| Check | Result |
|---|---|
| `kd.exe` listening? | yes, UDP 50000 on IPv4 and IPv6 |
| Windows Firewall | inbound allow rules for `kd.exe`, Private and Public |
| NIC type in `.vmx` | both `e1000e` (KDNET-supported; `vmxnet3` is not) |
| Guest `bcdedit /dbgsettings` (user pasted) | key and port matched, `hostip 192.168.155.1`, `debug Yes` |

Everything that could be checked from the host was fine. The remaining questions were all
inside the guest: which NIC had KDNET actually bound to, and why were no packets arriving.

## The blocker

Answering that meant running a dozen commands in the guest and reading their output. Two
options:

1. Ask the user to type each command into the VM console and paste the result back. Slow, and
   the first attempt already failed because PowerShell ate `{current}` as a script block.
2. Use `vmrun runProgramInGuest`, which needs `-gu <user> -gp <password>`.

Option 2 is the right tool, but the agent must not be the one holding the password. The user
asked the obvious question: "can't I just put it in a file or encode it for you?" Encoding
changes nothing; the agent would still be passing the secret. A file the **user** creates, read
by a wrapper the **agent** merely calls, does change things. That became
`vmrun-guest.ps1` reading a `Get-Credential | Export-Clixml` file, later generalised into this
repository.

## What the guest said

With a non-admin profile, a script copied into `C:\Users\Public\...` and run through a `.cmd`
launcher (after discovering that inline arguments get mangled) returned:

```
Ethernet0  Intel 82574L   Up           00-1B-21-3A-5C-7E   PCI bus 3   192.168.155.131
Ethernet1  Intel 82574L   Not Present  00-1B-21-3A-5C-7F   PCI bus 27  (no IP)   PnP status: Error
kdnic      Stopped
```

A NIC that Windows reports as *Not Present / Error* while the hypervisor says it is connected
is the signature of KDNET owning it. Cross-check on the host: `vmnetdhcp.leases` showed MAC
`...5c:7f` taking a 192.168.14.x lease at every boot. So KDNET was on the **host-only** NIC,
sending to a `hostip` on the **NAT** subnet, through a host-only network whose DHCP hands out
`option routers 0.0.0.0`. No route, no packets, no connection.

## The fix

One line in the guest, as admin, then a reboot:

```
bcdedit /dbgsettings net hostip:192.168.14.1 port:50000 key:<key>
```

The alternative, `bcdedit /set '{dbgsettings}' busparams 3.0.0` to force the NAT NIC, was
rejected: pinning the debugger to the host-only NIC keeps the NAT NIC free for normal guest
networking, which is the better long-term layout.

Result, from `kd-log.txt`:

```
Connected to Windows 10 26100 x64 target at (Thu Oct 29 13:26:48.040 2026 (UTC + 9:00)), ptr64 TRUE
Kernel Debugger connection established.
```

The admin profile was verified the same way the user profile had been: `whoami /groups` through
the wrapper showed `BUILTIN\Administrators` with a `High Mandatory Level` token, so UAC was not
filtering VMware Tools' logon and `bcdedit` would work from the wrapper too.

## What generalised

| Lesson | Where it lives now |
|---|---|
| User stores the credential, agent calls a wrapper | `setup/`, `backends/`, `docs/credential-model.md` |
| Hypervisor CLIs mangle inline args; copy a script and run that | the `job` verb, `PROMPT.md` |
| Non-admin guests cannot write to the drive root; use a public work folder | `guestWorkDir` default |
| Long host paths break copies | `Get-VabJobDir` keeps launchers under the config directory |
| Separate `user` and `admin` profiles | `-Profile` |
| Verify a stored credential with one harmless call, not by re-typing it | setup step 4 |
| Quote `{current}` in PowerShell | `PROMPT.md` gotchas |
