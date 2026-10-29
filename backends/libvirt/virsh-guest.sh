#!/usr/bin/env bash
# vm-agent-bridge backend for libvirt/QEMU using the QEMU guest agent (virsh qemu-agent-command).
# Verbs: status | push <host> <guest> | pull <guest> <host> | run <guestScript> [--no-wait] | reboot
#        job <hostScript> | raw <json-qmp-command>
#
# Credential model: NONE. The guest agent runs as root inside the guest and libvirt authorizes the
# host user through its own policy (libvirt group / polkit). Profiles in config.json are ignored.
# Set LIBVIRT_DEFAULT_URI (e.g. qemu:///system) if needed. Requires: virsh, jq, base64.
# Status: reference implementation (QEMU guest agent protocol), not yet verified end to end.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"

no_wait=0 args=()
cmd="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in --no-wait) no_wait=1; shift ;; --profile) shift 2 ;; *) args+=("$1"); shift ;; esac
done
[ -n "$cmd" ] || vab_die "usage: $(basename "$0") <status|push|pull|run|reboot|job|raw> ..."
vab_load_config
command -v virsh >/dev/null 2>&1 || vab_die "virsh not found"

qga() { virsh qemu-agent-command "$VAB_VM" "$1" --timeout 30; }

# guest-exec with wait; prints stdout/stderr (base64-decoded) and returns the exit code
guest_exec() {  # guest_exec <path> [args...]
  local path="$1"; shift
  local argjson pid st
  argjson="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  pid="$(qga "$(jq -nc --arg p "$path" --argjson a "$argjson" '{execute:"guest-exec",arguments:{path:$p,arg:$a,"capture-output":true}}')" | jq -r '.return.pid')"
  [ "$no_wait" = 1 ] && { echo "started pid $pid"; return 0; }
  while :; do
    st="$(qga "$(jq -nc --argjson pid "$pid" '{execute:"guest-exec-status",arguments:{pid:$pid}}')")"
    [ "$(echo "$st" | jq -r '.return.exited')" = "true" ] && break
    sleep 1
  done
  echo "$st" | jq -r '.return."out-data" // empty' | base64 -d || true
  echo "$st" | jq -r '.return."err-data" // empty' | base64 -d >&2 || true
  return "$(echo "$st" | jq -r '.return.exitcode // 1')"
}

guest_write_file() {  # guest_write_file <hostPath> <guestPath>
  local h
  h="$(qga "$(jq -nc --arg p "$2" '{execute:"guest-file-open",arguments:{path:$p,mode:"wb"}}')" | jq -r '.return')"
  base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n' | fold -w 65536 | while read -r chunk; do
    qga "$(jq -nc --argjson h "$h" --arg b "$chunk" '{execute:"guest-file-write",arguments:{handle:$h,"buf-b64":$b}}')" >/dev/null
  done
  qga "$(jq -nc --argjson h "$h" '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null
}
guest_read_file() {  # guest_read_file <guestPath> <hostPath>
  local h r
  h="$(qga "$(jq -nc --arg p "$1" '{execute:"guest-file-open",arguments:{path:$p,mode:"r"}}')" | jq -r '.return')"
  : > "$2"
  while :; do
    r="$(qga "$(jq -nc --argjson h "$h" '{execute:"guest-file-read",arguments:{handle:$h,count:65536}}')")"
    echo "$r" | jq -r '.return."buf-b64"' | base64 -d >> "$2"
    [ "$(echo "$r" | jq -r '.return.eof')" = "true" ] && break
  done
  qga "$(jq -nc --argjson h "$h" '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null
}
interp() { if [ "$VAB_GUEST_OS" = "windows" ]; then printf '%s\n' 'C:\Windows\System32\cmd.exe' /c "$1"; else printf '%s\n' /bin/sh "$1"; fi; }

case "$cmd" in
  status)
    echo "VM        : $VAB_VM"
    state="$(virsh domstate "$VAB_VM" 2>/dev/null || echo unknown)"; echo "Power     : $state"
    [ "$state" = "running" ] || exit 10
    if out="$(qga '{"execute":"guest-ping"}' 2>&1)"; then echo "Agent     : responding"; else echo "Agent     : NOT responding - $out"; exit 11; fi
    echo "Auth      : n/a (guest agent runs as root; access controlled by libvirt policy)" ;;
  push)  [ ${#args[@]} -eq 2 ] || vab_die "usage: push <hostPath> <guestPath>"; guest_write_file "${args[0]}" "${args[1]}"; echo "pushed ${args[0]} -> ${args[1]}" ;;
  pull)  [ ${#args[@]} -eq 2 ] || vab_die "usage: pull <guestPath> <hostPath>"; guest_read_file "${args[0]}" "${args[1]}"; echo "pulled ${args[0]} -> ${args[1]}" ;;
  run)   [ ${#args[@]} -eq 1 ] || vab_die "usage: run <guestScript> [--no-wait]"; mapfile -t ia < <(interp "${args[0]}"); guest_exec "${ia[@]}" ;;
  reboot) virsh reboot "$VAB_VM" --mode agent && echo 'reboot requested via guest agent. Poll "status".' ;;
  job)
    [ ${#args[@]} -eq 1 ] || vab_die "usage: job <hostScript>"
    host_script="$(cd "$(dirname "${args[0]}")" && pwd)/$(basename "${args[0]}")"; leaf="$(basename "$host_script")"; base="${leaf%.*}"
    job_dir="$(vab_job_dir)"; host_log="$job_dir/$base.log"
    guest_script="$(vab_guest_path "$leaf")"; guest_launcher="$(vab_guest_path "$base$(vab_launcher_ext)")"; guest_log="$(vab_guest_path "$base.log")"
    if [ "$VAB_GUEST_OS" = "windows" ]; then guest_exec 'C:\Windows\System32\cmd.exe' /c "mkdir $VAB_GUEST_WORK_DIR" >/dev/null 2>&1 || true
    else guest_exec /bin/mkdir -p "$VAB_GUEST_WORK_DIR" >/dev/null 2>&1 || true; fi
    host_launcher="$job_dir/$base$(vab_launcher_ext)"; vab_launcher_text "$guest_script" "$guest_log" > "$host_launcher"
    guest_write_file "$host_script" "$guest_script"; guest_write_file "$host_launcher" "$guest_launcher"
    mapfile -t ia < <(interp "$guest_launcher"); guest_exec "${ia[@]}" >/dev/null 2>&1 || true
    guest_read_file "$guest_log" "$host_log"
    echo "---- $leaf (guest log: $guest_log, host copy: $host_log) ----"; cat "$host_log"; echo "----"
    rc="$(vab_exit_code_from_log "$host_log")"; [ -n "$rc" ] || { echo "warning: no RC= line in log" >&2; exit 1; }
    exit "$rc" ;;
  raw)   [ ${#args[@]} -eq 1 ] || vab_die "usage: raw '<json qemu-agent command>'"; qga "${args[0]}" ;;
  *) vab_die "unknown verb '$cmd'" ;;
esac
