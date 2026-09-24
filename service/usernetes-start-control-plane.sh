#!/bin/bash
#
# Usernetes control plane user service. Shared setup lives in usernetes-common.sh;
# this script only does the control-plane-specific kubeadm steps.

set -euo pipefail

# First argument (from the .service file) selects the container engine.
export USERNETES_CONTAINER_TECH="${1:-${USERNETES_CONTAINER_TECH:-podman}}"

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=usernetes-common.sh
source "${here}/usernetes-common.sh"

# Home, PATH, kubectl, rabbit-backed podman storage, template copy, image
# builds, and stale cleanup. Leaves us in ${TMPDIR}/usernetes.
usernetes_common_setup control-plane

# quick mode disables checking rp_filter
log "    ⬆️ Bringing up the Usernetes node(s) with 'make up-built'"
if ! QUICK=1 make up-built; then
    error_exit "Failed to bring up Usernetes with 'make up-built'."
fi
sleep 3
usernetes_node_vxlan_fixups

log "🔐 Running kubeadm-init with 'make kubeadm-init'"
if ! make kubeadm-init; then
    error_exit "Failed 'make kubeadm-init'."
fi
sleep 3

log "🥷 Creating kubeconfig with 'make kubeconfig'"
if ! make kubeconfig; then
    error_exit "Failed 'make kubeconfig'."
fi
export KUBECONFIG="${TMPDIR}/usernetes/kubeconfig"
log "KUBECONFIG set to: ${KUBECONFIG}"
log "To use this cluster from another terminal: source ${TMPDIR}/usernetes/source_env.sh"

# Ensure the kubeconfig is readable by the user
chmod 600 "${KUBECONFIG}"
sleep 3

# Get control plane node name robustly
log "🍑 Untainting control plane and labeling node"
control_plane_node=""

# Retry a few times for the node to be ready
for i in $(seq 1 5); do
    control_plane_node=$(kubectl --kubeconfig="${KUBECONFIG}" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$control_plane_node" ]]; then
        break
    fi
    log "Control plane node not found yet, retrying... ($i/5)"
    sleep 5
done

if [[ -z "$control_plane_node" ]]; then
    error_exit "Could not identify control plane node."
fi
log "Control plane node: ${control_plane_node}"

# Taint away!
kubectl --kubeconfig="${KUBECONFIG}" taint node "${control_plane_node}" node-role.kubernetes.io/control-plane:NoSchedule- || log "WARN: Failed to untaint node. It might already be untainted or another issue occurred."
kubectl --kubeconfig="${KUBECONFIG}" label node "${control_plane_node}" node.kubernetes.io/exclude-from-external-load-balancers- || log "WARN: Failed to label node. It might already be labeled or another issue occurred."

log "📄 Current Kubernetes Nodes:"
kubectl --kubeconfig="${KUBECONFIG}" get nodes -o wide

log "🔗 Generating join command with 'make join-command'"
make join-command
log "🏃‍➡️ Copying to ${USERNETES_SHARED_DIR}"
chmod +x join-command
cp join-command "${USERNETES_SHARED_DIR}/"

log "🎉 Usernetes Control Plane setup complete. Kubeconfig is at: ${KUBECONFIG}"
log "    Next, once workers have joined, from ${TMPDIR}/usernetes:"
log "      . source_env.sh && make install-cni && make sync-external-ip"
log "🚀 Service will now idle indefinitely. Process ID: $$"

# Keep the script running so systemd considers the service active.
# The actual k8s processes are managed by containerd/kubelet inside the usernetes_node container.
sleep infinity
