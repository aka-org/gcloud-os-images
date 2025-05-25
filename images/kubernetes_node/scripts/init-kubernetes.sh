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
        echo "Checking status of load balancers..."
	sleep 10
        lb_status="$(curl http://$CONTROLPLANE_ENDPOINT:8081/health 2>/dev/null)"
        lb_status="${lb_status:-""}"
    done
    echo "Load Balancers are OK."
}

set_kubernetes_secret() {
    local init_output="$1"
    local token=""
    local hash=""
    local secret_value=""
    echo "Storing kubernetes token and hash in secret $KUBERNETES_SECRET..."
    # Extract token and hash
    token=$(echo "$init_output" | grep -oP '(?<=--token )\S+'| head -n1)
    hash=$(echo "$init_output" | grep -oP '(?<=--discovery-token-ca-cert-hash sha256:)\S+'| head -n1)

    # Compose secret value
    secret_value="${token}:${hash}"
    # Combine and push to Secret Manager
    printf "%s" "$secret_value" | gcloud secrets versions add $KUBERNETES_SECRET --data-file=-
    echo "Secret $KUBERNETES_SECRET updated."
}

get_kubernetes_secret() {
    local secret=""
    # Retrieve token and hash from GCP Secret Manager
    while [ -z "$secret" ]; do
        echo "Fetching kubernetes token and hash from secret $KUBERNETES_SECRET..."
        sleep 10
        secret=$(gcloud secrets versions access latest --secret="$KUBERNETES_SECRET" 2>/dev/null)
	secret="${secret:-""}"
    done
    TOKEN=$(echo "$secret" | cut -d':' -f1)
    HASH=$(echo "$secret" | cut -d':' -f2)
    sed -i "s|{{TOKEN}}|$TOKEN|g" $CONFIG
    sed -i "s|{{HASH}}|$HASH|g" $CONFIG
    echo "Secret $KUBERNETES_SECRET fetched."
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
    echo "Control plane IP is $CONTROLPLANE_ENDPOINT."
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
    # Read the lines into variables
    mapfile -t LB_ARRAY <<< "$lb_ips"
    LB1="${LB_ARRAY[0]}"
    LB2="${LB_ARRAY[1]}"
    sed -i "s|{{LB1}}|$LB1|g" $CONFIG
    sed -i "s|{{LB2}}|$LB2|g" $CONFIG
    echo "Load Balancer IPs are $LB1 and $LB2."
}

join_cluster() {
    echo "Joining node $(hostname) to the $CLUSTER_NAME..."
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
    
    kubeadm join --config $CONFIG
    echo "Node $(hostname) joined the $CLUSTER_NAME."
}


init_cluster() {
    local init_output=""
    
    echo "Initializing Kubernetes Cluster $CLUSTER_NAME..."
    if [ $HA_ENABLED == "true" ]; then
        get_lb_ips
	check_lbs
    fi
    # replace placeholders in kubeadm manifests
    sed -i "s|{{HOST_IP}}|$HOST_IP|g" $CONFIG
    sed -i "s|{{CONTROLPLANE_ENDPOINT}}|$CONTROLPLANE_ENDPOINT|g" $CONFIG
    sed -i "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" $CONFIG

    # Run kubeadm init
    init_output=$(kubeadm init --config $CONFIG 2>&1)

    # Store kuebernetes token and hash in gcloud secret
    set_kubernetes_secret "$init_output"
 
    echo "Applying Calico CNI..."
    # Export kubeconfig file path
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Install CNI operator and Calico
    kubectl create -f $CALICO_OPERATOR
    kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s
    kubectl create -f $CALICO_RESOURCES
    echo "Kubernetes Cluster $CLUSTER_NAME initialized."
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
    init_cluster
elif [[ "$ROLE" == "$MASTER_ROLE" && $INIT_CLUSTER != "true" ]]; then
    CONFIG="/etc/kubeadm/master-join.yaml"
    join_cluster
elif [[ "$ROLE" == "$WORKER_ROLE" ]]; then
    CONFIG="/etc/kubeadm/worker-join.yaml"
    join_cluster
else
    echo "Role $ROLE is invalid."
    exit 1
fi
