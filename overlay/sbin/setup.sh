#!/bin/sh

# Network Bringup
ip link set lo up
ip link set eth0 up 2>/dev/null

# see /usr/share/udhcpc/default.script
udhcpc -i eth0 -n -q -t 5 &

(sleep 5; ntpd -d -n -q -p pool.ntp.org) &

# Greeting
clear
cat /etc/motd
echo "Network setup complete."
