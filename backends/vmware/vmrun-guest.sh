#!/usr/bin/env bash
# vm-agent-bridge backend for VMware Fusion / Workstation on macOS or Linux (vmrun).
# Same verbs as vmrun-guest.ps1:
#   status [--profile p] | push <host> <guest> | pull <guest> <host> | run <guestScript> [--no-wait]
#   reboot | job <hostScript> [--profile p] | raw <vmrunCommand> [args...]
# Status: reference implementation (written against the vmrun manual, not yet exercised on a Unix host).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"

profile="user" no_wait=0 args=()
cmd="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --no-wait) no_wait=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$cmd" ] || vab_die "usage: $(basename "$0") <status|push|pull|run|reboot|job|raw> ..."

vab_load_config
[ "$VAB_BACKEND" = "vmware" ] || echo "warning: config backend is '$VAB_BACKEND', using vmware wrapper" >&2

if [ -n "${VMRUN:-}" ]; then vmrun="$VMRUN"
elif command -v vmrun >/dev/null 2>&1; then vmrun="$(command -v vmrun)"
elif [ -x "/Applications/VMware Fusion.app/Contents/Public/vmrun" ]; then vmrun="/Applications/VMware Fusion.app/Contents/Public/vmrun"
else vab_die "vmrun not found; set VMRUN"; fi
host_type="ws"; [ "$(uname -s)" = "Darwin" ] && host_type="fusion"

vmrun_plain() { "$vmrun" -T "$host_type" "$@"; }
vmrun_auth() {
  local user pw
  user="$(vab_profile_field "$profile" username)"
  pw="$(vab_secret "$profile")"
  "$vmrun" -T "$host_type" -gu "$user" -gp "$pw" "$@"
}
interp_args() {
  if [ "$VAB_GUEST_OS" = "windows" ]; then
    case "$1" in *" "*) vab_die "guest script path must not contain spaces";; esac
    printf '%s\n%s\n' 'C:\Windows\System32\cmd.exe' "/c $1"
  else printf '%s\n%s\n' '/bin/sh' "$1"; fi
}
ensure_workdir() {
  if vmrun_auth directoryExistsInGuest "$VAB_VM" "$VAB_GUEST_WORK_DIR" 2>/dev/null | grep -q 'exists'; then return; fi
  vmrun_auth createDirectoryInGuest "$VAB_VM" "$VAB_GUEST_WORK_DIR" >/dev/null 2>&1 || true
}

case "$cmd" in
  status)
    echo "VM        : $VAB_VM"
    if vmrun_plain list | grep -Fxq "$VAB_VM"; then echo "Power     : running"; else echo "Power     : not running"; exit 10; fi
    echo "Tools     : $(vmrun_plain checkToolsState "$VAB_VM")"
    if out="$(vmrun_auth listProcessesInGuest "$VAB_VM" 2>&1)"; then echo "Auth ($profile) : OK ($(echo "$out" | head -n1))"
    else echo "Auth ($profile) : FAILED - $out"; exit 11; fi ;;
  push)  [ ${#args[@]} -eq 2 ] || vab_die "usage: push <hostPath> <guestPath>"
         vmrun_auth copyFileFromHostToGuest "$VAB_VM" "${args[0]}" "${args[1]}" && echo "pushed ${args[0]} -> ${args[1]}" ;;
  pull)  [ ${#args[@]} -eq 2 ] || vab_die "usage: pull <guestPath> <hostPath>"
         vmrun_auth copyFileFromGuestToHost "$VAB_VM" "${args[0]}" "${args[1]}" && echo "pulled ${args[0]} -> ${args[1]}" ;;
  run)   [ ${#args[@]} -eq 1 ] || vab_die "usage: run <guestScript> [--no-wait]"
         mapfile -t ia < <(interp_args "${args[0]}")
         if [ "$no_wait" = 1 ]; then vmrun_auth runProgramInGuest "$VAB_VM" -noWait "${ia[@]}"; else vmrun_auth runProgramInGuest "$VAB_VM" "${ia[@]}"; fi ;;
  reboot) vmrun_plain reset "$VAB_VM" soft && echo 'reboot requested (graceful). Poll "status" until Tools is running again.' ;;
  job)
    [ ${#args[@]} -eq 1 ] || vab_die "usage: job <hostScript> [--profile p]"
    host_script="$(cd "$(dirname "${args[0]}")" && pwd)/$(basename "${args[0]}")"
    leaf="$(basename "$host_script")"; base="${leaf%.*}"
    case "$leaf" in *" "*) vab_die "script file name must not contain spaces";; esac
    job_dir="$(vab_job_dir)"
    guest_script="$(vab_guest_path "$leaf")"
    guest_launcher="$(vab_guest_path "$base$(vab_launcher_ext)")"
    guest_log="$(vab_guest_path "$base.log")"
    host_launcher="$job_dir/$base$(vab_launcher_ext)"
    host_log="$job_dir/$base.log"
    ensure_workdir
    vab_launcher_text "$guest_script" "$guest_log" > "$host_launcher"
    vmrun_auth copyFileFromHostToGuest "$VAB_VM" "$host_script" "$guest_script"
    vmrun_auth copyFileFromHostToGuest "$VAB_VM" "$host_launcher" "$guest_launcher"
    mapfile -t ia < <(interp_args "$guest_launcher")
    vmrun_auth runProgramInGuest "$VAB_VM" "${ia[@]}" || true
    rm -f "$host_log"
    vmrun_auth copyFileFromGuestToHost "$VAB_VM" "$guest_log" "$host_log"
    echo "---- $leaf (guest log: $guest_log, host copy: $host_log) ----"
    cat "$host_log"; echo "----"
    rc="$(vab_exit_code_from_log "$host_log")"
    [ -n "$rc" ] || { echo "warning: no RC= line in log" >&2; exit 1; }
    exit "$rc" ;;
  raw)   [ ${#args[@]} -ge 1 ] || vab_die "usage: raw <vmrunCommand> [args...]"
         vmrun_auth "${args[0]}" "$VAB_VM" "${args[@]:1}" ;;
  *) vab_die "unknown verb '$cmd'" ;;
esac
