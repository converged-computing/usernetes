#!/bin/bash

# Install standard Calico (downloaded in Dockerfile on build)
CALICO_FILE="/calico.yaml"

# backend to vxlan
yq eval-all -i '(select(.kind == "ConfigMap" and .metadata.name == "calico-config").data.calico_backend) = "vxlan"' $CALICO_FILE

# Disable IPIP and enable CrossSubnet VXLAN for IPv4/IPv6 in the Calico manifest
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
