#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# Use cgroup v2
sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 /' /etc/default/grub
update-grub

echo "[+] Loading required kernel modules"

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

echo "[+] Setting sysctl parameters for Kubernetes & Calico"

cat <<EOF | tee /etc/sysctl.d/99-k8s-calico.conf
# Enable IP forwarding
net.ipv4.ip_forward=1

# Required for Calico to correctly see bridged traffic
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1

# Optional: Avoid issues with reverse path filtering
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

# Apply settings immediately
sysctl --system

echo "[+] Installing containerd"
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
# Configure containerd 
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's|^\s*sandbox_image = .*|sandbox_image = "registry\.k8s\.io/pause:3\.10"|' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

echo "[+] Installing Required Packages"
apt-get install -y \
  --no-install-recommends \
  --option=Dpkg::Options::="--force-confdef" \
  --option=Dpkg::Options::="--force-confold" \
  apt-transport-https ca-certificates curl gpg iproute2 iptables socat conntrack 
echo "[+] Installing Kubernetes components"
# Save key securely
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# Add repo with signed-by option
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | tee \
  /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y \
  --no-install-recommends \
  --option=Dpkg::Options::="--force-confdef" \
  --option=Dpkg::Options::="--force-confold" \
  kubelet kubeadm kubectl 
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

swapoff -a
sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
