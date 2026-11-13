# Backends

All wrappers expose the same verbs; see the table in the [README](../README.md#the-common-interface).
This page lists what each hypervisor needs, how the credential reaches it, and the quirks that
shaped the wrapper.

| Backend | Script | Verified |
|---|---|---|
| VMware Workstation / Fusion / Player | `backends/vmware/vmrun-guest.ps1`, `vmrun-guest.sh` | **ps1: yes** (Win11 host, WS 26, Win11 guest); sh: no |
| VirtualBox | `backends/virtualbox/vbox-guest.ps1`, `vbox-guest.sh` | no |
| Hyper-V | `backends/hyperv/hyperv-guest.ps1` | no |
| libvirt / QEMU | `backends/libvirt/virsh-guest.sh` | no |

"Verified" means exercised end to end against a real VM. The others follow the documented CLI
and will probably need small fixes on first contact. Please send them.

## VMware (`vmrun`)

- **Needs:** VMware Tools running in the guest. `vmrun` ships with Workstation/Fusion/Player.
  `-T ws` on Windows/Linux, `-T fusion` on macOS; the wrapper picks.
- **Credential path:** `vmrun -gu <user> -gp <password>`. There is no file or stdin option. The
  password is visible in the host process list for the duration of the call.
- **Encrypted VM images:** when VMware reports `A password is required for this operation`,
  run `setup/windows/New-VmEncryptionCredential.ps1` yourself. It stores a separate DPAPI
  credential under `vmEncryption` and the wrapper injects `-vp <password>` into every vmrun
  call as well as `-gu/-gp`. The image password and the guest account password are distinct;
  the setup prompt never reveals either one to the agent. Like `-gp`, `-vp` is visible to a
  local administrator in the host process list during that call. Without this optional config,
  the original unencrypted-VM behavior is unchanged.
- **Quirks that matter:**
  - `runProgramInGuest` mangles program arguments: inline commands grow stray empty arguments
    and lose quotes. This is why `job` exists. The wrapper passes exactly one argument string
    (`/c <path>`) and refuses guest paths containing spaces.
  - `runScriptInGuest` has been seen to hang indefinitely. Not used.
  - Host-side paths over roughly 200 characters make `copyFileFromHostToGuest` fail with
    "A file was not found". The wrapper warns; keep job scripts in a short path.
  - A non-admin guest account cannot write to `C:\` or other users' profiles. The default work
    folder `C:\Users\Public\vm-agent-bridge` is writable by everyone.
  - `reset <vmx> soft` is a graceful restart through Tools and needs no credential. Sent while
    the guest is still booting it may be applied late or dropped; poll `status` first.
  - Exit code `-196608` from `runProgramInGuest` usually means the program path did not exist.
  - Guest console output is OEM code page (CP949, CP437, ...). Have guest scripts write with
    `Out-File -Encoding utf8`; the wrapper reads logs as UTF-8.
  - Admin guest accounts get a full High-integrity token through Tools (UAC does not filter
    it), so `bcdedit`, service control and the like work from `-Profile admin`.

## VirtualBox (`VBoxManage guestcontrol`)

- **Needs:** Guest Additions running (run level 2 or higher). VBoxManage 6.1+ for `--passwordfile`.
- **Credential path:** `--username <user> --passwordfile <file>`. The wrapper writes the file
  into your credential directory (already ACL/mode locked), uses it for one call, deletes it in
  a `finally`. Nothing on the command line.
- **Quirks:**
  - `copyto`/`copyfrom` keep the source file name and take `--target-directory`. `push`/`pull`
    therefore require the destination to end with the same file name or to be a directory.
  - `run` needs `--exe <absolute path>` plus the argv after `--` (argv[0] repeated by convention).
  - `--wait-stdout --wait-stderr` streams output; without them `run` returns immediately.
  - Reboot is done inside the guest (`shutdown /r /t 0` or `systemctl reboot`); on Linux that
    needs a privileged profile.

## Hyper-V (PowerShell Direct)

- **Needs:** elevated PowerShell on the host, Hyper-V module, Windows guest with integration
  services. `vm` in config is the VM *name*, not a path.
- **Credential path:** a `PSCredential` object passed to `New-PSSession -VMName` /
  `Invoke-Command -VMName`. No plaintext anywhere. This is the model the other hypervisors
  should have.
- **Quirks:**
  - `job` does not need the launcher: `Invoke-Command -FilePath` runs the host script inside
    the guest and streams output back. Script exit codes come from `$LASTEXITCODE` if your
    script sets one; otherwise the wrapper reports 0 unless the remote call threw.
  - `Copy-Item -ToSession/-FromSession` handles file transfer.
  - Linux guests would need PowerShell installed in the guest; not covered.

## libvirt / QEMU (`virsh qemu-agent-command`)

- **Needs:** `qemu-guest-agent` running in the guest, a virtio-serial channel, `virsh`, `jq`.
- **Credential path:** none. The agent runs as root in the guest; libvirt decides whether *you*
  may talk to the domain (libvirt group, polkit). Profiles are ignored; `--profile` is accepted
  and discarded so the agent-facing interface stays identical.
- **Quirks:**
  - File transfer is `guest-file-open/write/read/close` with base64 chunks. Fine for scripts and
    logs, slow for anything large.
  - `guest-exec` returns a pid; the wrapper polls `guest-exec-status` once per second.
  - `virsh reboot --mode agent` is the graceful path.
  - On Windows guests the QEMU guest agent service must be installed from the virtio-win ISO.

## Adding a backend

Copy the closest wrapper, keep the verbs and their exit codes (`10` = VM not running, `11` =
auth failed, `12` = host prerequisite missing, otherwise the guest script's code), load the
credential through `lib/common.*`, and never let the password reach stdout, stderr or a log.
Add a row to the tables above with "Verified: no" until someone has run it for real.
