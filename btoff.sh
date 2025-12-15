#!/bin/sh
MAC="BC:87:FA:A1:15:33"

# Disconnect the device
bluetoothctl disconnect "$MAC"

# Optionally power off bluetooth when not needed
bluetoothctl power off

