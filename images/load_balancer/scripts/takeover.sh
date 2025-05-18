#!/bin/bash
PEER_NAME=$1
GCP_ZONE=$2
LB_VIP=$3

# Unassign peer's IP aliases. Try it until it's possible.
until gcloud compute instances network-interfaces update $PEER_NAME \
  --zone $GCP_ZONE --aliases "" > /etc/keepalived/takeover.log 2>&1; do
    echo "Instance not accessible during takeover. Retrying in 5 seconds..."
    sleep 5
done
# Assign IP aliases to MASTER
gcloud compute instances network-interfaces update $(hostname) \
  --zone $GCP_ZONE --aliases "$LB_VIP/32" >> /etc/keepalived/takeover.log 2>&1
systemctl restart haproxy
echo "$(hostname) became MASTER at: $(date)" >> /etc/keepalived/takeover.log
