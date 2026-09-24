#!/bin/bash
#
# Usernetes worker user service. Shared setup lives in usernetes-common.sh;
# this script only does the worker-specific kubeadm join.

set -euo pipefail

# First argument (from the .service file) selects the container engine.
export USERNETES_CONTAINER_TECH="${1:-${USERNETES_CONTAINER_TECH:-podman}}"

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=usernetes-common.sh
source "${here}/usernetes-common.sh"

# The control plane leaves the join command on the shared filesystem.
# Check before doing any expensive setup.
if [[ ! -f "${USERNETES_SHARED_DIR}/join-command" ]]; then
    error_exit "Cannot find join-command in ${USERNETES_SHARED_DIR}. Is the control plane up?"
fi

# Home, PATH, kubectl, rabbit-backed podman storage, template copy, image
# builds, and stale cleanup. Leaves us in ${TMPDIR}/usernetes.
usernetes_common_setup worker

# quick mode disables checking rp_filter, which only matters for flannel
log "    ⬆️ Bringing up the Usernetes node(s) with 'make up-built'"
if ! QUICK=1 make up-built; then
    error_exit "Failed to bring up Usernetes with 'make up-built'."
fi
sleep 3
usernetes_node_vxlan_fixups

# Copy the join-command
cp "${USERNETES_SHARED_DIR}/join-command" join-command
chmod +x join-command

# The join command carries the control plane's address as "<ip>  <node-name>".
# Check the API server answers from this host before kubeadm tries from inside
# the node container, so an address or dead-control-plane problem is obvious.
control_plane_ip=$(grep -oP '^echo "\K[0-9.]+(?=  u7s-)' join-command | head -1 || true)
if [[ -n "${control_plane_ip}" ]]; then
    log "🔎 Checking the control plane API server at https://${control_plane_ip}:${PORT_KUBE_APISERVER:-6443}"
    if curl -sk --max-time 10 "https://${control_plane_ip}:${PORT_KUBE_APISERVER:-6443}/version" > /dev/null; then
        log "    ✅ API server is reachable from $(hostname)"
    else
        log "    ❌ Nothing answers on ${control_plane_ip}:${PORT_KUBE_APISERVER:-6443} from $(hostname)."
        log "       On the control plane check: podman ps; curl -sk https://127.0.0.1:${PORT_KUBE_APISERVER:-6443}/version; ip route get 1"
        error_exit "Control plane API server not reachable; not attempting kubeadm join."
    fi
else
    log "    WARNING: could not parse the control plane address from join-command; continuing"
fi

log "🤝 Joining the cluster with 'make kubeadm-join'"
if ! make kubeadm-join; then
    error_exit "Failed 'make kubeadm-join'."
fi

log "🎉 Usernetes worker node setup complete."
log "    To use podman against this node's storage: source ${TMPDIR}/usernetes/source_env.sh"
log "🚀 Service will now idle indefinitely. Process ID: $$"

# Keep the script running so systemd considers the service active.
# The actual k8s processes are managed by containerd/kubelet inside the usernetes_node container.
sleep infinity
