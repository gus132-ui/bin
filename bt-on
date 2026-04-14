#!/bin/sh
# Connect Bose "Earmuffs" and set A2DP

MAC="BC:87:FA:A1:15:33"
CARD_PATTERN="bluez_card.BC_87_FA_A1_15_33"
SINK_PATTERN="bluez_output.BC_87_FA_A1_15_33"

echo "Waking up Bluetooth adapter..."

# 1) Make sure Bluetooth is unblocked and powered on
rfkill unblock bluetooth 2>/dev/null

bluetoothctl --timeout 5 power on >/dev/null 2>&1

# 2) Wait up to 5s until adapter reports Powered: yes
for i in 1 2 3 4 5; do
    if bluetoothctl show | awk '/Powered:/ {print $2}' | grep -q yes; then
        break
    fi
    sleep 1
done

if ! bluetoothctl show | awk '/Powered:/ {print $2}' | grep -q yes; then
    echo "Bluetooth adapter is still not powered. Aborting."
    exit 1
fi

# 3) Try to connect
echo "Attempting to connect to $MAC ..."
if ! bluetoothctl --timeout 10 connect "$MAC"; then
    echo "Connection failed. Make sure the headphones are ON, near the laptop,"
    echo "and not connected to another device, then run bton.sh again."
    exit 1
fi

# 4) Give PipeWire a moment to create card/sink
sleep 2

# 5) Force A2DP profile if card exists
CARD="$(pactl list short cards | awk -v pat="$CARD_PATTERN" '$2 ~ pat {print $2; exit}')"
if [ -n "$CARD" ]; then
    pactl set-card-profile "$CARD" a2dp-sink >/dev/null 2>&1
fi

# 6) Set the sink as default if it exists
SINK="$(pactl list short sinks | awk -v pat="$SINK_PATTERN" '$2 ~ pat {print $2; exit}')"
if [ -n "$SINK" ]; then
    pactl set-default-sink "$SINK" >/dev/null 2>&1
fi

echo "Headphones should now be connected and set as default output."

