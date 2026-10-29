#!/usr/bin/env bash
# Shared helpers for the vm-agent-bridge shell backends. Source this file.
# Requires: jq. Secrets come from the OS store (macOS Keychain or Secret Service via secret-tool).
# Nothing in here echoes a password. Keep it that way.

vab_die() { echo "vm-agent-bridge: $*" >&2; exit 1; }

vab_config_path() {
  if [ -n "${VM_AGENT_BRIDGE_CONFIG:-}" ]; then echo "$VM_AGENT_BRIDGE_CONFIG"; return; fi
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/vm-agent-bridge/config.json"
}

vab_load_config() {
  command -v jq >/dev/null 2>&1 || vab_die "jq is required (brew install jq / apt install jq)"
  VAB_CONFIG="$(vab_config_path)"
  [ -f "$VAB_CONFIG" ] || vab_die "config not found at '$VAB_CONFIG'. The user must run setup/unix/new-guest-credential.sh first."
  VAB_BACKEND="$(jq -r '.backend' "$VAB_CONFIG")"
  VAB_VM="$(jq -r '.vm' "$VAB_CONFIG")"
  VAB_GUEST_OS="$(jq -r '.guestOS // "linux"' "$VAB_CONFIG")"
  VAB_CRED_DIR="$(jq -r '.credDir // ""' "$VAB_CONFIG")"
  if [ "$VAB_GUEST_OS" = "windows" ]; then
    VAB_GUEST_WORK_DIR="$(jq -r '.guestWorkDir // "C:\\Users\\Public\\vm-agent-bridge"' "$VAB_CONFIG")"
  else
    VAB_GUEST_WORK_DIR="$(jq -r '.guestWorkDir // "/tmp/vm-agent-bridge"' "$VAB_CONFIG")"
  fi
  [ -n "$VAB_VM" ] && [ "$VAB_VM" != "null" ] || vab_die "config is missing 'vm'"
}

# vab_profile_field <profile> <field>
vab_profile_field() {
  local v
  v="$(jq -r --arg p "$1" --arg f "$2" '.profiles[$p][$f] // empty' "$VAB_CONFIG")"
  [ -n "$v" ] || vab_die "profile '$1' has no '$2' in $VAB_CONFIG"
  echo "$v"
}

# vab_secret <profile>  -> prints the password to stdout (capture it, never echo it)
vab_secret() {
  local profile="$1" store ref
  store="$(vab_profile_field "$profile" store)"
  ref="$(vab_profile_field "$profile" ref)"
  case "$store" in
    keychain)
      command -v security >/dev/null 2>&1 || vab_die "'security' not found; keychain store needs macOS"
      security find-generic-password -s vm-agent-bridge -a "$ref" -w 2>/dev/null \
        || vab_die "keychain item 'vm-agent-bridge/$ref' not found. The user must create it with setup/unix/new-guest-credential.sh --profile $profile"
      ;;
    secret-tool)
      command -v secret-tool >/dev/null 2>&1 || vab_die "'secret-tool' not found (apt install libsecret-tools)"
      secret-tool lookup service vm-agent-bridge profile "$ref" \
        || vab_die "secret-tool item for profile '$ref' not found. The user must create it with setup/unix/new-guest-credential.sh --profile $profile"
      ;;
    *) vab_die "credential store '$store' is not supported by the shell backends (use keychain or secret-tool)" ;;
  esac
}

vab_guest_path() {
  if [ "$VAB_GUEST_OS" = "windows" ]; then printf '%s\\%s' "${VAB_GUEST_WORK_DIR%\\}" "$1"
  else printf '%s/%s' "${VAB_GUEST_WORK_DIR%/}" "$1"; fi
}

vab_job_dir() {
  local d; d="$(dirname "$(vab_config_path)")/jobs"
  mkdir -p "$d"; echo "$d"
}

# vab_launcher_text <guest-script> <guest-log>
vab_launcher_text() {
  local script="$1" log="$2"
  if [ "$VAB_GUEST_OS" = "windows" ]; then
    case "${script##*.}" in
      ps1) inner="powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$script\"" ;;
      cmd|bat) inner="call \"$script\"" ;;
      *) vab_die "unsupported guest script extension for a Windows guest (.ps1/.cmd/.bat)" ;;
    esac
    printf '@echo off\r\n%s > "%s" 2>&1\r\necho RC=%%ERRORLEVEL%% >> "%s"\r\n' "$inner" "$log" "$log"
  else
    printf '#!/bin/sh\n/bin/sh '"'"'%s'"'"' > '"'"'%s'"'"' 2>&1\necho RC=$? >> '"'"'%s'"'"'\n' "$script" "$log" "$log"
  fi
}

vab_launcher_ext() { if [ "$VAB_GUEST_OS" = "windows" ]; then echo ".launcher.cmd"; else echo ".launcher.sh"; fi; }

vab_exit_code_from_log() { sed -n 's/^RC=\(-\{0,1\}[0-9]\{1,\}\)[[:space:]]*$/\1/p' "$1" | tail -n 1; }
