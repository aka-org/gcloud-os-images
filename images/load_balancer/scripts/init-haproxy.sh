#!/bin/bash

# Label filters (allow override or use positional args)
VERSION="${1:-}"
ENV="${2:-testing}"
ROLE="${3:-kubernetes-master}"

HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

# Wait until at least one master node is discoverable
while true; do
    sleep 20
    echo "Discovering control plane nodes..."
    INSTANCES=$(gcloud compute instances list \
      --filter="labels.env=$ENV AND labels.version=$VERSION AND labels.role=$ROLE" \
      --format="table(name, networkInterfaces[0].networkIP)" 2>/dev/null)

    COUNT=$(echo "$INSTANCES" | tail -n +2 | wc -l)

    if [[ "$COUNT" -ge 1 ]]; then
        echo "Found $COUNT instances:"
        echo "$INSTANCES"
        break
    fi
done

# Append discovered nodes as HAProxy servers
echo "$INSTANCES" | tail -n +2 | while read -r NAME IP; do
    echo "  server ${NAME} ${IP}:6443 check" >> $HAPROXY_CONFIG
done

# Restart HAProxy to apply the config
echo "Restarting HAProxy..."
systemctl enable --now haproxy

echo "HAProxy is configured and running."
