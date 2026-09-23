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

log "    ⬆️ Bringing up the Usernetes node(s) with 'make up-built'"
if ! make up-built; then
    error_exit "Failed to bring up Usernetes with 'make up-built'."
fi
sleep 3

# Copy the join-command
cp "${USERNETES_SHARED_DIR}/join-command" join-command
chmod +x join-command

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
