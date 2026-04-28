#!/bin/sh
set -eu

# Generate host keys on first boot — emptyDir is fresh each restart, which
# is fine for a demo.
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
fi

# sshd needs this dir to exist for PrivilegeSeparation.
mkdir -p /run/sshd

# Foreground; -e sends logs to stderr so kubectl logs sees them.
exec /usr/sbin/sshd -D -e
