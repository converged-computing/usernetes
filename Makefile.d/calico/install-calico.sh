#!/bin/bash

# Install standard Calico
CALICO_VERSION="v3.31"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/refs/heads/release-${CALICO_VERSION}/manifests/calico.yaml

# Allow initial creation, then cleanup
# This seems necessary because without, ip addr will not show complete setup
sleep 10

# Delete objects we will customize and re-create
kubectl delete deployments.apps -n kube-system calico-kube-controllers
kubectl delete cm -n kube-system calico-config
kubectl delete daemonsets.apps -n kube-system calico-node

# These are for our corona images
yq eval -i '(.spec.template.spec.initContainers[] | select(.name == "upgrade-ipam") | .image) = "ghcr.io/converged-computing/usernetes:calico-cni"' ./Makefile.d/calico/deploy/daemonset.yaml
yq eval -i '(.spec.template.spec.initContainers[] | select(.name == "install-cni") | .image) = "ghcr.io/converged-computing/usernetes:calico-cni"' ./Makefile.d/calico/deploy/daemonset.yaml
yq eval -i '(.spec.template.spec.initContainers[] | select(.name == "ebpf-bootstrap") | .image) = "ghcr.io/converged-computing/usernetes:calico-node"' ./Makefile.d/calico/deploy/daemonset.yaml
yq eval -i '(.spec.template.spec.containers[] | select(.name == "calico-node") | .image) = "ghcr.io/converged-computing/usernetes:calico-node"' ./Makefile.d/calico/deploy/daemonset.yaml
yq eval -i '(.spec.template.spec.containers[] | select(.name == "calico-kube-controllers") | .image) = "ghcr.io/converged-computing/usernetes:calico-kube-controllers"' ./Makefile.d/calico/deploy/deployment.yaml

# Update components with our version
# Note that IP autodetect has to initially be there so the vxlan.calico shows up
kubectl apply -f ./Makefile.d/calico/deploy

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
