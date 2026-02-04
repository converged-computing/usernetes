#!/bin/bash

# Install standard Calico
CALICO_VERSION="v3.31"
CALICO_FILE="calico.yaml"

# Create local bin
LOCAL_BIN_DIR=~/.local/bin
mkdir -p $LOCAL_BIN_DIR
export PATH=$LOCAL_BIN_DIR:$PATH

# 1. Download official manifest
wget https://raw.githubusercontent.com/projectcalico/calico/refs/heads/release-v3.31/manifests/calico.yaml -O $CALICO_FILE

install_yq() {
    if ! command -v yq > /dev/null; then
        log "Installing yq..."
        YQ_VERSION=v4.2.0
        YQ_PLATFORM=linux_amd64
        cd /tmp
        wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${YQ_PLATFORM}.tar.gz -O - | tar xz 
        chmod +x ./yq_${YQ_PLATFORM} 
        mv ./yq_${YQ_PLATFORM} "${LOCAL_BIN_DIR}/yq"
        log "      yq installed to ${LOCAL_BIN_DIR}/yq"
        cd -
    else
        log "      yq found at $(command -v yq)"
    fi
    command -v yq > /dev/null || error_exit "yq not found after installation attempt."
}

install_yq

# backend to vxlan
yq eval-all -i '(select(.kind == "ConfigMap" and .metadata.name == "calico-config").data.calico_backend) = "vxlan"' $CALICO_FILE

# Images for corona
yq eval-all -i '(select(.kind == "Deployment" and .metadata.name == "calico-kube-controllers").spec.template.spec.containers[0].image) = "ghcr.io/converged-computing/usernetes:calico-kube-controllers"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.initContainers[] | select(.name == "upgrade-ipam").image) = "ghcr.io/converged-computing/usernetes:calico-cni"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.initContainers[] | select(.name == "install-cni").image) = "ghcr.io/converged-computing/usernetes:calico-cni"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.initContainers[] | select(.name == "ebpf-bootstrap").image) = "ghcr.io/converged-computing/usernetes:calico-node"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].image) = "ghcr.io/converged-computing/usernetes:calico-node"' $CALICO_FILE

# IPIP and VXLAN
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env[] | select(.name == "CALICO_IPV4POOL_IPIP").value) = "Never"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env[] | select(.name == "CALICO_IPV4POOL_VXLAN").value) = "CrossSubnet"' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env[] | select(.name == "CALICO_IPV6POOL_VXLAN").value) = "CrossSubnet"' $CALICO_FILE

# FELIX for rootless
yq eval-all -i 'select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env += {"name": "FELIX_IGNORELOOSERPF", "value": "true"}' $CALICO_FILE
yq eval-all -i 'select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env += {"name": "FELIX_VXLANPORT", "value": "8472"}' $CALICO_FILE
yq eval-all -i 'select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].env += {"name": "FELIX_EXTERNALNODESCIDRLIST", "value": "10.100.0.0/16"}' $CALICO_FILE

# health probes (Remove bird-ready and bird-live)
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].livenessProbe.exec.command) = ["/bin/calico-node", "-felix-live"]' $CALICO_FILE
yq eval-all -i '(select(.kind == "DaemonSet" and .metadata.name == "calico-node").spec.template.spec.containers[0].readinessProbe.exec.command) = ["/bin/calico-node", "-felix-ready"]' $CALICO_FILE

# install components with our rootless version
kubectl apply -f ${CALICO_FILE}
echo "Done. Final file is $CALICO_FILE"

# Give a small break to settle - we need calico.vxlan to be created
sleep 10

# This must be removed or the address will be reset
kubectl set env daemonset/calico-node IP- -n kube-system

# Allow pods to recreate
echo "Recreating calico pods..."
sleep 10

# https://youtu.be/noriIzBKYRk?si=mlOC27ntvSEDw_VM&t=299
# These commands need to be done bringing up node
# iptables -I INPUT -p udp --dport 8472 -j ACCEPT
# sysctl -w net.ipv4.conf.all.rp_filter=2
# sysctl -w net.ipv4.conf.default.rp_filter=2
# sysctl -w net.ipv4.conf.eth0.rp_filter=2
# sysctl -w "net.ipv4.conf.vxlan/calico.rp_filter=2"  

# This needs to be done after daemonset is patched
# Note that the calico-node has a warning after this, but it won't work if we don't do it
for node in $(kubectl get nodes -o name); do
    host_ip="$(kubectl get "${node}" -o jsonpath='{.metadata.labels.usernetes/host-ip}')"
    nodename=$(cut -d / -f 2 <<< $node)
    calicoctl --allow-version-mismatch patch node ${nodename} --patch='{"spec": {"bgp":{"ipv4Address": "'"$host_ip"'"}}}'
done

# applies ethtool -K vxlan.calico tx-checksum-ip-generic off
# check with: bridge fdb show dev vxlan.calico should have node address NOT 10.x address
kubectl apply --server-side -f /usernetes/Makefile.d/calico/calico-ethtool.yaml

# These should be run after calico installed
# 1. make sync-external-ip and make install-calico
# the second has a daemonset to apply these commands
# ethtool -K vxlan.calico tx-checksum-ip-generic off
