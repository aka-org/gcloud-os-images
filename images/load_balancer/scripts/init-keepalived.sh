#!/bin/bash

set -euo pipefail

ROLE="$1"
VERSION="$2"
ENV="$3"
LB_VIP="$4"
ZONE="$5"
LB_PRIO="$6"
LB_STATE="$7"

# Get the private IP of the current instance
API_ENDPOINT="http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip"
SRC_IP=$(curl -s -H "Metadata-Flavor: Google" "$API_ENDPOINT")

# Find the peer load-balancer name and IP
PEER_NAME=""
PEER_IP=""

while [ -z "$PEER_IP" ]; do
    echo "Waiting for peer K8s load balancer IP..."
    sleep 2
    read -r PEER_NAME PEER_IP <<< "$(
        gcloud compute instances list \
            --format="json" \
            --filter="networkInterfaces[0].networkIP!=$SRC_IP AND labels.role=$ROLE AND labels.version=$VERSION AND labels.env=$ENV" 2>/dev/null |
        jq -r '.[0] | "\(.name) \(.networkInterfaces[0].networkIP)"'
    )" || true

    PEER_IP="${PEER_IP:-""}"
done

echo "Found peer $PEER_NAME with IP $PEER_IP"

# Replace placeholders in Keepalived configuration
sed -i "s|{{SRC_IP}}|$SRC_IP|g" /etc/keepalived/keepalived.conf
sed -i "s|{{PEER_IP}}|$PEER_IP|g" /etc/keepalived/keepalived.conf
sed -i "s|{{PEER_NAME}}|$PEER_NAME|g" /etc/keepalived/keepalived.conf
sed -i "s|{{LB_VIP}}|$LB_VIP|g" /etc/keepalived/keepalived.conf
sed -i "s|{{ZONE}}|$ZONE|g" /etc/keepalived/keepalived.conf
sed -i "s|{{LB_PRIO}}|$LB_PRIO|g" /etc/keepalived/keepalived.conf
sed -i "s|{{LB_STATE}}|$LB_STATE|g" /etc/keepalived/keepalived.conf

# Enable and start Keepalived
systemctl enable --now keepalived
