set -e

export DEBIAN_FRONTEND=noninteractive

# Modify Kernel settings to to allow
# more open file descriptors
echo "fs.nr_open = 1048599" | sudo tee -a /etc/sysctl.d/98-haproxy.conf
sysctl --system

echo "[+] Installing HAProxy"
apt-get install -y haproxy
systemctl stop haproxy
systemctl disable haproxy

echo "[+] Installing Keepalived"
apt-get install -y keepalived
systemctl stop keepalived
systemctl disable keepalived
