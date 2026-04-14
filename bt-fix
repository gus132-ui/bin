#!/bin/sh
# Reset Bluetooth adapter (run as root)

systemctl stop bluetooth.service
modprobe -r btusb
modprobe btusb
systemctl start bluetooth.service
rfkill unblock bluetooth
bluetoothctl power on

