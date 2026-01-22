#!/bin/bash

# These commands need to be done bringing up node
# iptables -I INPUT -p udp --dport 8472 -j ACCEPT
# sysctl -w net.ipv4.conf.all.rp_filter=2
# sysctl -w net.ipv4.conf.default.rp_filter=2
# sysctl -w net.ipv4.conf.eth0.rp_filter=2
# sysctl -w "net.ipv4.conf.vxlan/calico.rp_filter=2"  

# This needs to be done after daemonset is patched
for node in $(kubectl get nodes -o name); do
	host_ip="$(kubectl get "${node}" -o jsonpath='{.metadata.labels.usernetes/host-ip}')"
        nodename=$(cut -d / -f 2 <<< $node)
        calicoctl --allow-version-mismatch patch node ${nodename} --patch='{"spec": {"bgp":{"ipv4Address": "'"$host_ip"'"}}}'
done

# These should be run after calico installed
# 1. make sync-external-ip and make install-calico
# the second has a daemonset to apply these commands
# ethtool -K vxlan.calico tx-checksum-ip-generic off
