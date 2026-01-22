#!/bin/bash
set -eu -o pipefail

for node in $(kubectl get nodes -o name); do
	# Set ExternalIP
	host_ip="$(kubectl get "${node}" -o jsonpath='{.metadata.labels.usernetes/host-ip}')"
	kubectl patch "${node}" --type=merge --subresource status --patch \
		"\"status\": {\"addresses\": [{\"type\":\"ExternalIP\", \"address\": \"${host_ip}\"}]}"

	# Propagate ExternalIP to flannel
	# https://github.com/flannel-io/flannel/blob/v0.24.4/Documentation/kubernetes.md#annotations
	kubectl annotate "${node}" flannel.alpha.coreos.com/public-ip-overwrite=${host_ip}

	# Remove taints
	taints="$(kubectl get "${node}" -o jsonpath='{.spec.taints}')"
	if echo "${taints}" | grep -q node.cloudprovider.kubernetes.io/uninitialized; then
		kubectl taint nodes "${node}" node.cloudprovider.kubernetes.io/uninitialized-
	fi
        nodename=$(cut -d / -f 2 <<< $node)
        calicoctl --allow-version-mismatch patch node ${nodename} --patch='{"spec": {"bgp":{"ipv4Address": "'"$host_ip"'"}}}'

        iptables -I INPUT -p udp --dport 8472 -j ACCEPT
        sysctl -w net.ipv4.conf.all.rp_filter=2
        sysctl -w net.ipv4.conf.default.rp_filter=2
        sysctl -w net.ipv4.conf.eth0.rp_filter=2
        # These should be run after calico installed
        # 1. make sync-external-ip and install calico
        # 2. then these commands
        # ethtool -K vxlan.calico tx-checksum-ip-generic off
        # sysctl -w "net.ipv4.conf.vxlan/calico.rp_filter=2"  
done
