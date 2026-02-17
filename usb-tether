#!/bin/sh
IFACE=$(ip -br a | grep 'enx' | awk '{print $1}')

sudo ip link set "$IFACE" up
sudo dhcpcd "$IFACE"

GATEWAY=$(ip route | grep "$IFACE" | awk '/default/ {print $3}')

sudo ip route del default
sudo ip route add default via "$GATEWAY" dev "$IFACE"

echo "USB tethering active on $IFACE"

