#!/bin/sh
# Make Bluetooth adapter ready for use (no root)

# Unblock in case NetworkManager / airplane mode blocked it
rfkill unblock bluetooth 2>/dev/null

# Try to power on the adapter
bluetoothctl --timeout 5 power on >/dev/null 2>&1

# Optional: if you want to see status in logs:
# bluetoothctl show | awk '/Powered:/ {print "Bluetooth powered:", $2}'

