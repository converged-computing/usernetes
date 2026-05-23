#!/bin/bash
set -eux -o pipefail

# Append "KUBELET_EXTRA_ARGS=..." in /etc/default/kubelet
sed -e "s!\(^KUBELET_EXTRA_ARGS=.*\)!\\1 --cloud-provider=external --node-labels=usernetes/host-ip=${HOST_IP}!" </etc/default/kubelet | sponge /etc/default/kubelet

# Start the NRI plugin in the background
/opt/nri/plugins/usernetes-identity-nri --host-min 2048 --host-max 4095 &

# Import control plane hosts from previous boot
[ -e /etc/hosts.u7s ] && cat /etc/hosts.u7s >>/etc/hosts

exec "$@"
