#!/bin/sh

# Mounts
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup

# Network Bringup
ip link set eth0 up 2>/dev/null
udhcpc -i eth0 -n -q -t 5 2>/dev/null &

(sleep 15; ntpd -d -n -q -p pool.ntp.org) &

# Greeting
clear
cat /etc/motd
echo ""
