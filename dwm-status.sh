#!/bin/sh

while true; do
    datetime="$(date '+%a %m-%d %H:%M')"

    # Volume
    if command -v pamixer >/dev/null 2>&1; then
        vol="$(pamixer --get-volume-human 2>/dev/null)"
    elif command -v amixer >/dev/null 2>&1; then
        vol="$(amixer get Master | awk -F'[][]' 'END{print $2}')"
    else
        vol="n/a"
    fi

    # Network on/off
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
        net="online"
    else
        net="offline"
    fi

    # VPN (tun0 / wg0 / proton0 – adjust to match your system)
    if ip link show tun0 >/dev/null 2>&1 || ip link show wg0 >/dev/null 2>&1 || ip link show proton0 >/dev/null 2>&1; then
        vpn="VPN on"
    else
        vpn="VPN off"
    fi

    xsetroot -name "VOL $vol | NET $net | $vpn | $datetime    "
    sleep 5
done
