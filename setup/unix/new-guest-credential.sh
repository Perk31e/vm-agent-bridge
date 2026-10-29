#!/usr/bin/env bash
# Store a guest VM credential for vm-agent-bridge on macOS or Linux.
# RUN THIS YOURSELF, never through an AI agent.
#
#   1. Validates the credential directory (absolute, not in a Git repo, not cloud-synced,
#      not /tmp, owned by you), creates it, chmod 700.
#   2. Stores the password in the OS secret store:
#        macOS  -> Keychain  (security add-generic-password; it prompts and asks you to retype)
#        Linux  -> Secret Service (secret-tool); you type the password twice here, they must match
#      The user name goes into the non-secret config.json.
#   3. Verifies with one harmless guest call through the backend wrapper.
#
# Usage:
#   new-guest-credential.sh --backend vmware --vm "/path/to/vm.vmx" [--profile user]
#   new-guest-credential.sh --backend virtualbox --vm "Win11" --profile admin --cred-dir ~/secure/vab
#   new-guest-credential.sh --backend libvirt --vm "win11" --guest-os windows     (no credential needed)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
# shellcheck source=../../lib/common.sh
. "$repo_root/lib/common.sh"

backend="" vm="" profile="user" cred_dir="" guest_os="linux" guest_work_dir="" skip_verify=0
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) backend="$2"; shift 2 ;;
    --vm) vm="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --cred-dir) cred_dir="$2"; shift 2 ;;
    --guest-os) guest_os="$2"; shift 2 ;;
    --guest-work-dir) guest_work_dir="$2"; shift 2 ;;
    --skip-verify) skip_verify=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) vab_die "unknown option: $1" ;;
  esac
done
case "$backend" in vmware|virtualbox|libvirt) ;; *) vab_die "--backend must be vmware, virtualbox or libvirt" ;; esac
[ -n "$vm" ] || vab_die "--vm is required"
[[ "$profile" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || vab_die "--profile must match [A-Za-z0-9_-]{1,32}"
case "$guest_os" in windows|linux) ;; *) vab_die "--guest-os must be windows or linux" ;; esac
command -v jq >/dev/null 2>&1 || vab_die "jq is required"

os="$(uname -s)"
recommended="${XDG_CONFIG_HOME:-$HOME/.config}/vm-agent-bridge/creds"

echo
echo "vm-agent-bridge credential setup"
echo "  Backend : $backend"
echo "  VM      : $vm"
echo "  Profile : $profile"
echo

# ---- 1. credential directory (used for config + temp password files; secrets live in the OS store)
if [ -z "$cred_dir" ]; then
  echo "Where should vm-agent-bridge keep its credential directory?"
  echo "Recommended: $recommended"
  read -r -p "Credential directory [Enter = recommended]: " answer
  cred_dir="${answer:-$recommended}"
fi
cred_dir="${cred_dir/#\~/$HOME}"
case "$cred_dir" in /*) ;; *) vab_die "credential directory must be an absolute path" ;; esac

problems=()
d="$cred_dir"; while [ "$d" != "/" ] && [ -n "$d" ]; do
  [ -e "$d/.git" ] && { problems+=("is inside a Git repository ($d)"); break; }
  d="$(dirname "$d")"
done
case "$cred_dir" in
  "$repo_root"/*|"$repo_root") problems+=("is inside the vm-agent-bridge checkout") ;;
esac
case "$cred_dir" in
  /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"*) problems+=("is inside a temp folder") ;;
esac
case "$cred_dir" in
  *"/Library/Mobile Documents/"*|*/iCloud*|*/Dropbox/*|*/OneDrive*|*"/Google Drive/"*|*/GoogleDrive/*|*/Box/*)
    problems+=("looks like a cloud-synced folder; synced folders leak credentials to other devices") ;;
esac
if [ -e "$cred_dir" ]; then
  [ -d "$cred_dir" ] || problems+=("exists but is not a directory")
  if [ "$os" = "Darwin" ]; then owner="$(stat -f %u "$cred_dir")"; else owner="$(stat -c %u "$cred_dir")"; fi
  [ "$owner" = "$(id -u)" ] || problems+=("is owned by uid $owner, not by you (uid $(id -u))")
fi
if [ ${#problems[@]} -gt 0 ]; then
  echo "Refusing credential directory '$cred_dir':" >&2
  for p in "${problems[@]}"; do echo "  - $p" >&2; done
  exit 2
fi
mkdir -p "$cred_dir"; chmod 700 "$cred_dir"
echo "Using $cred_dir (mode 700)"

# ---- 2. secret ------------------------------------------------------------------------------
store="" ref="$profile" username=""
if [ "$backend" = "libvirt" ]; then
  echo "libvirt backend uses the QEMU guest agent, which runs as root inside the guest; no credential is stored."
  store="none"
else
  read -r -p "GUEST user name for profile '$profile': " username
  [ -n "$username" ] || vab_die "empty user name"
  if [ "$os" = "Darwin" ]; then
    command -v security >/dev/null 2>&1 || vab_die "'security' not found"
    store="keychain"
    echo "Keychain will now prompt for the GUEST password (and ask you to retype it)."
    security add-generic-password -U -s vm-agent-bridge -a "$ref" -l "vm-agent-bridge/$ref" -j "guest $username on $vm"
  else
    command -v secret-tool >/dev/null 2>&1 || vab_die "'secret-tool' not found (apt install libsecret-tools)"
    store="secret-tool"
    read -r -s -p "GUEST password: " pw1; echo
    read -r -s -p "Retype GUEST password: " pw2; echo
    [ "$pw1" = "$pw2" ] || vab_die "passwords do not match; nothing stored"
    [ -n "$pw1" ] || vab_die "empty password; nothing stored"
    printf '%s' "$pw1" | secret-tool store --label="vm-agent-bridge/$ref" service vm-agent-bridge profile "$ref"
    unset pw1 pw2
  fi
  echo "Stored secret for guest user '$username' (profile '$profile') in the OS secret store."
fi

# ---- 3. config.json ---------------------------------------------------------------------------
cfg_path="$(vab_config_path)"
mkdir -p "$(dirname "$cfg_path")"
[ -f "$cfg_path" ] || echo '{"profiles":{}}' > "$cfg_path"
if [ -z "$guest_work_dir" ]; then
  guest_work_dir="$(jq -r '.guestWorkDir // empty' "$cfg_path")"
  if [ -z "$guest_work_dir" ]; then
    if [ "$guest_os" = "windows" ]; then guest_work_dir='C:\Users\Public\vm-agent-bridge'; else guest_work_dir='/tmp/vm-agent-bridge'; fi
  fi
fi
tmp="$(mktemp)"
jq --arg b "$backend" --arg vm "$vm" --arg os "$guest_os" --arg wd "$guest_work_dir" --arg cd "$cred_dir" \
   --arg p "$profile" --arg u "$username" --arg s "$store" --arg r "$ref" \
   '.backend=$b | .vm=$vm | .guestOS=$os | .guestWorkDir=$wd | .credDir=$cd
    | .profiles[$p]={username:$u, store:$s, ref:$r}' "$cfg_path" > "$tmp" && mv "$tmp" "$cfg_path"
chmod 600 "$cfg_path"
echo "Wrote config $cfg_path (no secrets inside)"

# ---- 4. verify -----------------------------------------------------------------------------------
[ "$skip_verify" = 1 ] && { echo "Skipping verification."; exit 0; }
case "$backend" in
  vmware)     wrapper="$repo_root/backends/vmware/vmrun-guest.sh" ;;
  virtualbox) wrapper="$repo_root/backends/virtualbox/vbox-guest.sh" ;;
  libvirt)    wrapper="$repo_root/backends/libvirt/virsh-guest.sh" ;;
esac
echo
echo "Verifying with: $wrapper status --profile $profile"
if "$wrapper" status --profile "$profile"; then
  echo; echo "Done. The agent can now use the wrapper; it never needs the password."
else
  echo; echo "Credential stored, but verification FAILED (wrong user/password, guest agent not running, VM off?)." >&2
  echo "Fix and re-run this script to replace the credential." >&2
  exit 3
fi
