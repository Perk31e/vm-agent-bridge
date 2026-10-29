#!/bin/sh
# Example guest job (Linux guest): interfaces, addresses, routes. Everything to stdout.
# Run from the host:  <wrapper> job ./examples/collect-nic-info.sh
echo "=== whoami ==="; id -un
echo "=== interfaces ==="; ip -br link 2>/dev/null || ifconfig -a
echo "=== addresses ==="; ip -br addr 2>/dev/null || ifconfig
echo "=== routes ==="; ip route 2>/dev/null || netstat -rn
