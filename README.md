# vm-agent-bridge

**Let an AI agent operate your lab VMs without the agent ever seeing a guest password.**

An AI coding agent (Claude Code, Codex, Cursor, Copilot, your own) is great at
"copy this script into the VM, run it, bring the output back, reboot, check again".
The problem is authentication: every hypervisor CLI wants the guest account's
password, and the moment that password goes through the agent's chat window,
prompt, or tool call it is in a transcript you do not control.

vm-agent-bridge is a small, boring pattern that fixes that:

1. **You** store the guest credential once, in your own terminal, in the OS
   credential store (Windows DPAPI, macOS Keychain, Linux Secret Service),
   in a directory **you** choose and the setup script validates.
2. **The agent** only ever calls a thin wrapper (`run`, `push`, `pull`,
   `reboot`, `status`). The wrapper loads the credential and talks to the
   hypervisor. The agent never reads the file, never types the password,
   never sees it in output.
3. A ready-to-paste [`PROMPT.md`](PROMPT.md) tells the agent the rules and the
   patterns that actually work (spoiler: hypervisor CLIs mangle inline
   arguments, so you copy a script in and run *that*).

It came out of a real debugging session: an agent could not get a Windows
kernel debugger (KDNET) to connect to a VMware guest, and fixing it needed
dozens of commands *inside* the guest. See
[docs/case-study-kdnet.md](docs/case-study-kdnet.md).

> Scope: your own lab/test VMs on your own machine. This is not a remote
> management product and it does not try to be one.

## Supported backends

| Backend | Host | Credential path | Status |
|---|---|---|---|
| VMware Workstation / Fusion (`vmrun`) | Windows, macOS, Linux | wrapper → `vmrun -gu/-gp` | **Verified** (Windows host, Windows 11 guest) |
| VirtualBox (`VBoxManage guestcontrol`) | Windows, macOS, Linux | wrapper → `--passwordfile` (temp file in your locked-down cred dir) | Reference implementation, not yet verified |
| Hyper-V (PowerShell Direct) | Windows | `Invoke-Command -VMName -Credential` (no plaintext at all) | Reference implementation, not yet verified |
| libvirt / QEMU (`virsh` + qemu-guest-agent) | Linux | none needed (guest agent runs as root) | Reference implementation, not yet verified |

Details and per-backend caveats: [docs/backends.md](docs/backends.md).

## Quick start (Windows host, VMware)

```powershell
# 1. Run setup yourself (never let the agent run this step).
#    It asks where to keep credentials, validates the directory, locks its ACL,
#    pops the standard Windows credential dialog, stores the result with DPAPI,
#    writes a non-secret config.json, and verifies with one harmless guest call.
.\setup\windows\New-GuestCredential.ps1 -Backend vmware `
    -Vm "C:\Virtual Machines\Win11\Win11.vmx" -Profile user

# optional second profile for admin tasks
.\setup\windows\New-GuestCredential.ps1 -Backend vmware `
    -Vm "C:\Virtual Machines\Win11\Win11.vmx" -Profile admin

# Optional, for an ENCRYPTED VMware image (vmrun says "password is required"):
# stores the separate -vp credential with DPAPI. Run this yourself as well.
.\setup\windows\New-VmEncryptionCredential.ps1 -Profile user

# 2. Paste PROMPT.md into your agent's instructions (CLAUDE.md, .cursorrules, ...).

# 3. The agent now does things like:
.\backends\vmware\vmrun-guest.ps1 status
.\backends\vmware\vmrun-guest.ps1 job .\examples\collect-nic-info.ps1
.\backends\vmware\vmrun-guest.ps1 job .\my-admin-task.ps1 -Profile admin
.\backends\vmware\vmrun-guest.ps1 reboot
```

`job` is the command you will use most: it copies a `.ps1`/`.sh` into the
guest's shared work folder, generates a tiny launcher that redirects all output
to a log, runs it, pulls the log back, and prints it. No quoting problems, no
lost output.

## The common interface

Every backend script exposes the same five verbs (plus `job` and `raw`):

| Verb | What it does |
|---|---|
| `status [-Profile p]` | Is the VM up, is the guest agent running, does the credential authenticate? |
| `push <host> <guest>` | Copy a file into the guest |
| `pull <guest> <host>` | Copy a file out of the guest |
| `run <guest-script> [-NoWait]` | Run a script that is already inside the guest |
| `reboot` | Graceful guest restart |
| `job <host-script>` | push + launcher + run + pull log, in one step |
| `raw <args...>` | Pass-through to the hypervisor CLI with the credential injected |

`-Profile user` is the default; `-Profile admin` (or any name you defined at
setup) picks another stored credential.

## Where things live

| Thing | Default location | Secret? |
|---|---|---|
| Credential files / keychain items | **You choose at setup.** Recommended: `%LOCALAPPDATA%\vm-agent-bridge\creds` (Windows), `~/.config/vm-agent-bridge/creds` (Unix) | **Yes** |
| `config.json` (backend, VM id, cred dir, profile → username/ref) | `%LOCALAPPDATA%\vm-agent-bridge\config.json` or `~/.config/vm-agent-bridge/config.json`, override with `VM_AGENT_BRIDGE_CONFIG` | No |
| Guest work folder | `C:\Users\Public\vm-agent-bridge` (Windows guest), `/tmp/vm-agent-bridge` (Linux guest) | No |

The setup script refuses a credential directory that is inside a Git
repository, inside a cloud-synced folder (OneDrive, Dropbox, Google Drive,
iCloud), or not owned by you, and it strips inherited permissions so only you
and SYSTEM can read it. Why each rule exists:
[docs/credential-model.md](docs/credential-model.md).

## Repository layout

```
PROMPT.md                 rules + patterns to paste into the agent
setup/windows/            New-GuestCredential.ps1
setup/unix/               new-guest-credential.sh
backends/vmware/          vmrun-guest.ps1, vmrun-guest.sh
backends/virtualbox/      vbox-guest.ps1, vbox-guest.sh
backends/hyperv/          hyperv-guest.ps1
backends/libvirt/         virsh-guest.sh
lib/                      shared config/credential loaders
examples/                 guest-side job scripts
docs/                     credential model, backends, case study
```

## Honest limitations

- `vmrun` and `VBoxManage` take the password on their own command line or in a
  file. While the wrapper runs, a local administrator could read it from the
  process list. The pattern protects you from the **agent and its transcript**,
  not from a compromised host. Hyper-V PowerShell Direct has no such exposure.
- The agent still has full control of the guest through the wrapper. Scope the
  guest account accordingly (a non-admin profile for routine work, an admin
  profile only when needed).
- Only the VMware/Windows path has been exercised end to end. The others are
  written against the documented CLIs and marked as such; please open an issue
  or PR when you verify one.

## License

MIT. See [LICENSE](LICENSE).

Korean version: [README.ko.md](README.ko.md)
