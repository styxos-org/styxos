echo "init ERROR Missing /sbin/setup.sh." | socat - UNIX-SENDTO:log.sock
echo "stylo INFO Logging works." | socat - UNIX-SENDTO:log.sock
