#!/bin/bash

ENV="$1"
ROLE="$2"

# Discover the control-plane IPs
MASTER_IPS=""
while [ -z "$MASTER_IPS" ]; do
    echo "Waiting for control plane IPs..."
    sleep 5
    MASTER_IP=$(gcloud compute instances list \
      --filter="labels.env=${filter-env} AND labels.role=${filter-role}" \
      --format="value(networkInterfaces[0].networkIP)" 2>/dev/null | head -n 1)

    # Set to empty string if the result is empty or null
    MASTER_IP="$${MASTER_IP:-""}"
done
systemctl enable --now haproxy
