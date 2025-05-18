#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating system"
apt-get update
apt-get install -y \
  --no-install-recommends \
  --option=Dpkg::Options::="--force-confdef" \
  --option=Dpkg::Options::="--force-confold" \
  cloud-init
