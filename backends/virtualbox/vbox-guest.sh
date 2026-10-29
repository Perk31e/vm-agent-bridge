#!/usr/bin/env bash
# vm-agent-bridge backend for Oracle VirtualBox on macOS/Linux (VBoxManage guestcontrol).
# Verbs: status [--profile p] | push <host> <guest> | pull <guest> <host> | run <guestScript> [--no-wait]
#        reboot | job <hostScript> [--profile p] | raw <guestcontrol-subcommand> [args...]
# Password goes to VBoxManage through --passwordfile (a short-lived file in your mode-700 cred dir), never argv.
# Status: reference implementation (VBoxManage 7.x manual), not yet verified end to end.
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
[ "$VAB_BACKEND" = "virtualbox" ] || echo "warning: config backend is '$VAB_BACKEND', using virtualbox wrapper" >&2
vbox="${VBOXMANAGE:-$(command -v VBoxManage || true)}"
[ -n "$vbox" ] || vab_die "VBoxManage not found; set VBOXMANAGE"
[ -n "$VAB_CRED_DIR" ] && [ -d "$VAB_CRED_DIR" ] || vab_die "credDir in config must exist (used for the short-lived password file)"

vbox_guest() {  # vbox_guest <sub> [args...]
  local sub="$1"; shift
  local user tmp rc=0
  user="$(vab_profile_field "$profile" username)"
  tmp="$(mktemp "$VAB_CRED_DIR/.tmp-XXXXXX.passwordfile")"
  chmod 600 "$tmp"
  vab_secret "$profile" | tr -d '\n' > "$tmp"
  "$vbox" guestcontrol "$VAB_VM" "$sub" --username "$user" --passwordfile "$tmp" "$@" || rc=$?
  rm -f "$tmp"
  return $rc
}
run_args() {
  if [ "$VAB_GUEST_OS" = "windows" ]; then printf '%s\n' --exe 'C:\Windows\System32\cmd.exe' -- cmd.exe /c "$1"
  else printf '%s\n' --exe /bin/sh -- sh "$1"; fi
}

case "$cmd" in
  status)
    info="$("$vbox" showvminfo "$VAB_VM" --machinereadable)" || vab_die "showvminfo failed"
    state="$(echo "$info" | sed -n 's/^VMState="\(.*\)"$/\1/p')"
    ga="$(echo "$info" | sed -n 's/^GuestAdditionsRunLevel=\(.*\)$/\1/p')"
    echo "VM        : $VAB_VM"; echo "Power     : $state"; echo "Additions : run level $ga"
    [ "$state" = "running" ] || exit 10
    if [ "$VAB_GUEST_OS" = "windows" ]; then who=(--exe 'C:\Windows\System32\whoami.exe' --wait-stdout -- whoami); else who=(--exe /usr/bin/id --wait-stdout -- id -un); fi
    if out="$(vbox_guest run "${who[@]}" 2>&1)"; then echo "Auth ($profile) : OK ($out)"; else echo "Auth ($profile) : FAILED - $out"; exit 11; fi ;;
  push)  [ ${#args[@]} -eq 2 ] || vab_die "usage: push <hostPath> <guestDir>"
         vbox_guest mkdir --parents "${args[1]}" >/dev/null 2>&1 || true
         vbox_guest copyto --target-directory "${args[1]}" "${args[0]}" && echo "pushed ${args[0]} -> ${args[1]}" ;;
  pull)  [ ${#args[@]} -eq 2 ] || vab_die "usage: pull <guestPath> <hostDir>"
         mkdir -p "${args[1]}"; vbox_guest copyfrom --target-directory "${args[1]}" "${args[0]}" && echo "pulled ${args[0]} -> ${args[1]}" ;;
  run)   [ ${#args[@]} -eq 1 ] || vab_die "usage: run <guestScript> [--no-wait]"
         mapfile -t ra < <(run_args "${args[0]}")
         if [ "$no_wait" = 1 ]; then vbox_guest run "${ra[@]}"; else vbox_guest run --wait-stdout --wait-stderr "${ra[@]}"; fi ;;
  reboot)
    if [ "$VAB_GUEST_OS" = "windows" ]; then vbox_guest run --exe 'C:\Windows\System32\shutdown.exe' -- shutdown /r /t 0
    else vbox_guest run --exe /bin/sh -- sh -c 'systemctl reboot || reboot'; fi
    echo 'reboot requested. Poll "status" until Additions run level is back.' ;;
  job)
    [ ${#args[@]} -eq 1 ] || vab_die "usage: job <hostScript> [--profile p]"
    host_script="$(cd "$(dirname "${args[0]}")" && pwd)/$(basename "${args[0]}")"
    leaf="$(basename "$host_script")"; base="${leaf%.*}"
    job_dir="$(vab_job_dir)"
    guest_script="$(vab_guest_path "$leaf")"; guest_launcher="$(vab_guest_path "$base$(vab_launcher_ext)")"; guest_log="$(vab_guest_path "$base.log")"
    host_launcher="$job_dir/$base$(vab_launcher_ext)"; host_log="$job_dir/$base.log"
    vbox_guest mkdir --parents "$VAB_GUEST_WORK_DIR" >/dev/null 2>&1 || true
    vab_launcher_text "$guest_script" "$guest_log" > "$host_launcher"
    vbox_guest copyto --target-directory "$VAB_GUEST_WORK_DIR" "$host_script" "$host_launcher"
    mapfile -t ra < <(run_args "$guest_launcher")
    vbox_guest run --wait-stdout --wait-stderr "${ra[@]}" || true
    rm -f "$host_log"
    vbox_guest copyfrom --target-directory "$job_dir" "$guest_log"
    echo "---- $leaf (guest log: $guest_log, host copy: $host_log) ----"; cat "$host_log"; echo "----"
    rc="$(vab_exit_code_from_log "$host_log")"; [ -n "$rc" ] || { echo "warning: no RC= line in log" >&2; exit 1; }
    exit "$rc" ;;
  raw)   [ ${#args[@]} -ge 1 ] || vab_die "usage: raw <guestcontrol-subcommand> [args...]"
         vbox_guest "${args[0]}" "${args[@]:1}" ;;
  *) vab_die "unknown verb '$cmd'" ;;
esac
