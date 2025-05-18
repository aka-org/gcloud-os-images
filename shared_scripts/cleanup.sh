#!/bin/bash
set -euxo pipefail

echo "[*] Starting GCE image cleanup..."

# Clean machine IDs
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
ln -s /etc/machine-id /var/lib/dbus/machine-id || true

# Clean logs
rm -rf /var/log/wtmp /var/log/btmp
rm -rf /var/log/*.log /var/log/**/*.log || true
rm -rf /var/log/journal/*
rm -rf /var/log/syslog /var/log/auth.log /var/log/secure || true

# Clean cloud-init data (if installed)
if command -v cloud-init &>/dev/null; then
    cloud-init clean --logs
    rm -rf /var/lib/cloud/*
fi

# Remove temporary files
rm -rf /tmp/* /var/tmp/*
rm -rf /var/lib/dhcp/*

# Clean APT cache
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# Zero out disk (optional: comment this out if space/time is tight)
echo "[*] Zeroing out free space..."
dd if=/dev/zero of=/EMPTY bs=1M || true
rm -f /EMPTY

# Sync to flush file system buffers
sync

echo "[✔] Cleanup complete. Ready to create image."
