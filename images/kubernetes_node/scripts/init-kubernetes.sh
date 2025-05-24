#!/bin/bash

set -euo pipefail

LB_VIP="$1"
VERSION="$2"
ENV="$3"
ROLE="$4"
CLUSTER_NAME="$5"
INIT_CLUSTER="$6"
KUBERNETES_SECRET="$7"

# These will be checked against label role of vm and ROLE variable
MASTER_ROLE="kubernetes-master"
LB_ROLE="kubernetes-lb"
WORKER_ROLE="kubernetes-worker"
CALICO_OPERATOR="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/tigera-operator.yaml"
CALICO_RESOURCES="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/custom-resources.yaml"

HA_ENABLED="false"
TOKEN=""
HASH=""
CONTROLPLANE_ENDPOINT=""
LB1=""
LB2=""

# Get the private ip and zone of the instance
METADATA_ENDPOINT="http://metadata.google.internal/computeMetadata/v1/instance"
HOST_IP=$(curl -s -H "Metadata-Flavor: Google" "$METADATA_ENDPOINT/network-interfaces/0/ip" | awk -F'/' '{print $NF}')

check_lbs() {
    local lb_status=""
    while [ -z "$lb_status" ]; do
        echo "Waiting for load balancers..."
	sleep 10
        lb_status="$(curl http://$CONTROLPLANE_ENDPOINT:8081/health 2>/dev/null)"
        lb_status="${lb_status:-""}"
    done
}

set_kubernetes_secret() {
    local init_output="$1"
    local token=""
    local hash=""
    # Extract token and hash
    token=$(echo "$init_output" | grep -oP '(?<=--token )\S+')
    hash=$(echo "$init_output" | grep -oP '(?<=--discovery-token-ca-cert-hash sha256:)\S+')

    # Combine and push to Secret Manager
    echo -n "${token}:${hash}" | gcloud secrets versions add $KUBERNETES_SECRET --data-file=-
}

get_kubernetes_secret() {
    local secret
    # Retrieve token and hash from GCP Secret Manager
    secret=$(gcloud secrets versions access latest --secret="$KUBERNETES_SECRET")
    TOKEN=$(echo "$secret" | cut -d':' -f1)
    HASH=$(echo "$secret" | cut -d':' -f2)
    sed -i "s|{{TOKEN}}|$TOKEN|g" $CONFIG
    sed -i "s|{{HASH}}|$HASH|g" $CONFIG
}

get_master_ip() {
    # Discover the control-plane ip
    local master_ip=""
    while [ -z "$master_ip" ]; do
        echo "Waiting for control plane IP..."
        sleep 10
        master_ip=$(gcloud compute instances list \
          --filter="labels.env=$ENV AND labels.version=$VERSION AND labels.role=$MASTER_ROLE" \
          --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)

        # Set to empty string if the result is empty or null
        master_ip="${master_ip:-""}"
    done
    CONTROLPLANE_ENDPOINT="$master_ip"
}

get_lb_ips() {
    # Discover the control-plane ip
    local lb_ips=""
    while [ -z "$lb_ips" ]; do
        echo "Waiting for load balancer IPs..."
        sleep 10
        lb_ips=$(gcloud compute instances list \
          --filter="labels.env=$ENV AND labels.version=$VERSION AND labels.role=$LB_ROLE" \
          --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)

        # Set to empty string if the result is empty or null
        lb_ips="${lb_ips:-""}"
    done
    lb_ips="$(echo $lb_ips | head -n 1),$(echo $lb_ips | tail -n 1)"
    LB1="$(echo $lb_ips | head -n 1)"
    LB2="$(echo $lb_ips | tail -n 1)"
    sed -i "s|{{LB1}}|$LB1|g" $CONFIG
    sed -i "s|{{LB2}}|$LB2|g" $CONFIG
}

join_cluster() {
    if [ $HA_ENABLED == "true" ]; then
        get_lb_ips
	check_lbs
    else
        get_master_ip
    fi
    get_kubernetes_secret

    # replace placeholders in kubeadm manifests
    sed -i "s|{{HOST_IP}}|$HOST_IP|g" $CONFIG
    sed -i "s|{{CONTROLPLANE_ENDPOINT}}|$CONTROLPLANE_ENDPOINT|g" $CONFIG
    
    # Sleep a while before joining
    sleep 45
    kubeadm join --config $CONFIG
}


init_cluster() {
    local init_output=""
    
    if [ $HA_ENABLED == "true" ]; then
        get_lb_ips
	check_lbs
    fi
    # replace placeholders in kubeadm manifests
    sed -i "s|{{HOST_IP}}|$HOST_I|g" $CONFIG
    sed -i "s|{{CONTROLPLANE_ENDPOINT}}|$CONTROLPLANE_ENDPOINT|g" $CONFIG
    sed -i "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" $CONFIG

    # Run kubeadm init
    init_output=$(kubeadm init --config $CONFIG 2>&1)

    # Store kuebernetes token and hash in gcloud secret
    set_kubernetes_secret $init_output

    # Export kubeconfig file path
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Install CNI operator and Calico
    kubectl create -f $CALICO_OPERATOR
    kubectl create -f $CALICO_RESOURCES
}

if [ $LB_VIP != "null" ]; then
    HA_ENABLED="true"
    CONTROLPLANE_ENDPOINT="$LB_VIP"
fi

if [[ "$ROLE" == "$MASTER_ROLE" && $INIT_CLUSTER == "true" ]]; then
    if [ $HA_ENABLED == "true" ]; then
        CONFIG="/etc/kubeadm/kubeadm-init-ha.yaml"
    else
        CONFIG="/etc/kubeadm/kubeadm-init.yaml"
	CONTROLPLANE_ENDPOINT="$HOST_IP"
    fi
    echo "Initializing Kubernetes Cluster $CLUSTER_NAME."
    init_cluster
elif [[ "$ROLE" == "$MASTER_ROLE" && $INIT_CLUSTER != "true" ]]; then
    CONFIG="/etc/kubeadm/master-join.yaml"
    join_cluster
    echo "Master node $(hostname) joined the $CLUSTER_NAME"
elif [[ "$ROLE" == "$WORKER_ROLE" ]]; then
    CONFIG="/etc/kubeadm/worker-join.yaml"
    join_cluster
    echo "Worker node $(hostname) joined the $CLUSTER_NAME"
else
    echo "Role $ROLE is invalid"
    exit 1
fi
