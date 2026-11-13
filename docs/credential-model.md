# Credential model

## The one property that matters

**The guest password never enters the agent's context.** Not in the prompt, not in a tool call,
not in tool output, not in a file the agent reads. Everything else in this repository exists to
make that property easy to keep.

Why that property and not "encrypt it well": an AI agent's transcript is the least controlled
place your data can be. It may be logged by the vendor, kept for training or abuse review,
summarised into memory files, forwarded to sub-agents, or pasted into an issue tracker by the
agent itself. Encryption does not help if the plaintext was typed into chat first. Base64 or any
"encoding" the agent performs is the same thing with extra steps.

## Roles

| Step | Who | Where |
|---|---|---|
| Choose the credential directory | **User** | their own terminal |
| Enter the guest user name and password | **User** | the OS credential dialog / prompt |
| Store it | setup script, run by the user | OS credential store |
| Optionally store a VMware encrypted-image password | user runs `New-VmEncryptionCredential.ps1` | DPAPI as `vmEncryption`, separate from the guest profiles |
| Use it | backend wrapper | process memory of the wrapper, for the duration of one hypervisor call |
| Call the wrapper | **Agent** | any tool that can run a command |

The agent never runs the setup script. If it did, the credential dialog would appear on the
user's screen under the agent's control, and the agent could read the resulting file. The
[`PROMPT.md`](../PROMPT.md) rules forbid both.

## Storage per platform

| Host OS | Store | Mechanism | Who can decrypt |
|---|---|---|---|
| Windows | DPAPI | `Get-Credential \| Export-Clixml` writes a PSCredential whose password is a DPAPI-protected SecureString | the same Windows user on the same machine (or with roaming DPAPI, the same domain user) |
| macOS | Keychain | `security add-generic-password`, service `vm-agent-bridge`, account = profile ref | the login keychain owner; first use by a new binary prompts once |
| Linux | Secret Service | `secret-tool store service vm-agent-bridge profile <ref>` (GNOME Keyring, KWallet via bridge) | the unlocked session keyring |

On Windows the file still has to live somewhere, hence the directory rules below. On macOS/Linux
the directory holds only the non-secret config and, for VirtualBox, a password file that exists
for milliseconds; it is still locked down (mode 700) because of that file.

## Directory rules (enforced by the setup scripts)

The user picks the directory. The script shows a recommendation, which is fine; what is not
fine is a location hard-coded in a public repository, because that is the first place anyone
looks. The script refuses a directory that:

| Rule | Why |
|---|---|
| is not an absolute, local path (no UNC share) | predictable resolution; no credentials on a file server you do not own |
| is inside a Git repository (any parent has `.git`) | one `git add -A` away from a public leak; `.gitignore` is a seatbelt, not a wall |
| is inside the vm-agent-bridge checkout | same reason, explicitly |
| is inside OneDrive, Dropbox, Google Drive, iCloud Drive, Box | sync copies the ciphertext to other devices where DPAPI cannot open it, and copies config and temp files that should never leave the machine |
| is inside TEMP | cleaned by tools you do not control; world-readable on some setups |
| is inside the current working directory (unless that is already under `%LOCALAPPDATA%`) | agents routinely list and read everything under their working directory |
| exists but is owned by another account | you cannot reason about its permissions |

After validation the Windows script runs `icacls /inheritance:r` and grants only your SID and
SYSTEM; the Unix script does `chmod 700` (directory) and `600` (config). The config file itself
contains no secrets, but it does reveal VM paths and the credential directory, which is more
than a public repo should know.

## Verification without re-entering the password

A natural instinct is "ask the user to type the password again to confirm it". That has two
problems: a second prompt is a second chance for the password to land in the wrong window
(the agent's chat, for instance), and typing it twice proves consistency, not correctness.

The setup scripts instead make **one harmless authenticated call** to the guest through the
backend wrapper (`status`): `vmrun listProcessesInGuest`, `VBoxManage guestcontrol run whoami`,
`Invoke-Command -VMName { whoami }`. If it succeeds the stored credential is right; if not, you
are told to re-run setup. On Linux, where `secret-tool` reads the password from a prompt without
a confirmation, the script does ask twice, but only in your own terminal, before anything is stored.

## Profiles

A profile is a named credential: `user` and `admin` by convention, any `[A-Za-z0-9_-]` name
works. The wrapper defaults to `user`. The agent is told to use `admin` only for the specific
call that needs it and to say so. This is the least-privilege lever you actually have: the agent
has the full power of whatever account the profile maps to.

## What this does not protect against

- **A compromised host.** `vmrun` takes `-gp <password>` and, for an encrypted VM image,
  `-vp <password>` on its command line; `VBoxManage` reads
  a password file. While the wrapper runs, a local administrator on the host can read either.
  Hyper-V PowerShell Direct passes a credential object in-process and has no such window.
- **An agent that ignores the rules.** `PROMPT.md` is instruction, not enforcement. If you need
  enforcement, run the agent as a different OS user than the one who owns the credential
  directory, so the file is unreadable to it and DPAPI would not decrypt it anyway.
- **What the agent does inside the guest.** It has whatever the profile's account has. Snapshots
  are your friend.
