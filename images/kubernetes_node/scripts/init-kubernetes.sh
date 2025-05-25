#!/bin/bash

set -euo pipefail

LB_VIP="$1"
VERSION="$2"
ENV="$3"
ROLE="$4"
CLUSTER_NAME="$5"
INIT_CLUSTER="$6"
KUBERNETES_DISCOVERY_SECRET="$7"
KUBERNETES_CERT_KEY_SECRET="$8"

# These will be checked against label role of vm and ROLE variable
MASTER_ROLE="kubernetes-master"
LB_ROLE="kubernetes-lb"
WORKER_ROLE="kubernetes-worker"
CALICO_OPERATOR="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/tigera-operator.yaml"
CALICO_RESOURCES="https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/custom-resources.yaml"

HA_ENABLED="false"
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

set_secret() {
    local secret="$1"
    local secret_value="$2"
    printf "%s" "$secret_value" | gcloud secrets versions add $secret --data-file=-
}

get_secret() {
    local secret="$1"
    local secret_value=""
    while [ -z "$secret_value" ]; do
        sleep 10
        secret_value=$(gcloud secrets versions access latest --secret="$secret" 2>/dev/null)
	secret_value="${secret_value:-""}"
    done
    echo "$secret_value"
}

set_kubernetes_cert_key_secret() {
    local cert_upload_output="$1"
    local secret_value=""
    echo "Storing kubernetes cert key in secret $KUBERNETES_CERT_KEY_SECRET..."
    # Extract token and hash
    secret_value="$(echo $cert_upload_output| awk '{print $NF}')"
    set_secret $KUBERNETES_CERT_KEY_SECRET "$secret_value"
    echo "Secret $KUBERNETES_CERT_KEY_SECRET updated."
}

get_kubernetes_cert_key_secret() {
    local secret_value=""
    # Retrieve token and hash from GCP Secret Manager
    secret_value="$(get_secret $KUBERNETES_CERT_KEY_SECRET)"
    sed -i "s|{{CERT_KEY}}|$secret_value|g" $CONFIG
    echo "Secret $KUBERNETES_CERT_KEY_SECRET fetched."
}

set_kubernetes_discovery_secret() {
    local init_output="$1"
    local token=""
    local hash=""
    local secret_value=""
    echo "Storing kubernetes token and hash in secret $KUBERNETES_DISCOVERY_SECRET..."
    # Extract token and hash
    token=$(echo "$init_output" | grep -oP '(?<=--token )\S+'| head -n1)
    hash=$(echo "$init_output" | grep -oP '(?<=--discovery-token-ca-cert-hash sha256:)\S+'| head -n1)

    # Compose secret value
    secret_value="${token}:${hash}"
    set_secret $KUBERNETES_DISCOVERY_SECRET "$secret_value"
    echo "Secret $KUBERNETES_DISCOVERY_SECRET updated."
}

get_kubernetes_discovery_secret() {
    local secret_value=""
    local token=""
    local hash=""
    # Retrieve token and hash from GCP Secret Manager
    secret_value="$(get_secret $KUBERNETES_DISCOVERY_SECRET)"
    token=$(echo "$secret_value" | cut -d':' -f1)
    hash=$(echo "$secret_value" | cut -d':' -f2)
    sed -i "s|{{TOKEN}}|$token|g" $CONFIG
    sed -i "s|{{HASH}}|$hash|g" $CONFIG
    echo "Secret $KUBERNETES_DISCOVERY_SECRET fetched."
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

join_master() {
    echo "Joining node $(hostname) to the $CLUSTER_NAME..."
    get_lb_ips
    check_lbs
    get_kubernetes_discovery_secret
    get_kubernetes_cert_key_secret
    # replace placeholders in kubeadm manifests
    sed -i "s|{{HOST_IP}}|$HOST_IP|g" $CONFIG
    sed -i "s|{{CONTROLPLANE_ENDPOINT}}|$CONTROLPLANE_ENDPOINT|g" $CONFIG

    kubeadm join phase control-plane-prepare download-certs $CONTROLPLANE_ENDPOINT:6443 --config $CONFIG
    kubeadm join --config $CONFIG
    echo "Node $(hostname) joined the $CLUSTER_NAME."
}

join_worker() {
    echo "Joining worker node $(hostname) to the $CLUSTER_NAME..."
    if [ $HA_ENABLED == "true" ]; then
        get_lb_ips
	check_lbs
    else
        get_master_ip
    fi
    get_kubernetes_discovery_secret

    sed -i "s|{{CONTROLPLANE_ENDPOINT}}|$CONTROLPLANE_ENDPOINT|g" $CONFIG

    kubeadm join --config $CONFIG
    echo "Worker node $(hostname) joined the $CLUSTER_NAME."
}

init_cluster() {
    local init_output=""
    local cert_upload_output=""
    
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
    set_kubernetes_discovery_secret "$init_output"
 
    if [ $HA_ENABLED == "true" ]; then
        cert_upload_output=$(kubeadm init phase upload-certs --upload-certs --config $CONFIG 2>&1)
        set_kubernetes_cert_key_secret "$cert_upload_output"
    fi

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
    join_master
elif [[ "$ROLE" == "$WORKER_ROLE" ]]; then
    CONFIG="/etc/kubeadm/worker-join.yaml"
    join_worker
else
    echo "Role $ROLE is invalid."
    exit 1
fi
