#!/bin/bash

set -euo pipefail

# These are variables we likely will change
# LC only supplies podman
USERNETES_CONTAINER_TECH=${1:-"podman"} 
USERNETES_TEMPLATE_PATH=/usr/workspace/usernetes/usernetes-develop

# We will copy join command here
shared_join_command_dir="/usr/workspace/usernetes"

# Logging functions for consistency (like Akihiro!)
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
}

error_exit() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2
    exit 1
}

# The user needs to run the setup script
USERNAME=$(whoami)

# This is way a lot for just deriving home, but I'm not convinced it will always
# be defined in the environment
if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
    user_home_dir=$(getent passwd "${USERNAME}" | cut -d: -f6)
    if [[ -z "${user_home_dir}" || ! -d "${user_home_dir}" ]]; then
        error_exit "Cannot determine user's home directory. HOME variable is not set or invalid, and getent failed."
    fi
    export HOME="${user_home_dir}"
    log "WARNING: HOME variable was not initially set or valid. Using '${HOME}' from system lookup."
fi

# Add user's local bin to PATH
LOCAL_BIN_DIR="${HOME}/.local/bin"
mkdir -p "${LOCAL_BIN_DIR}"
export PATH="${LOCAL_BIN_DIR}:${PATH}"
log "    Updated PATH: ${PATH}"

# Make sure we are using my local one
which podman-compose

# Write to /tmp but scoped to the username
# We don't want to use /var because that is a memory based fs
export TMPDIR="/tmp/${USERNAME}"

install_kubectl() {
    if ! command -v kubectl > /dev/null; then
        log "Installing kubectl..."
        curl -sSfLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x ./kubectl
        mv ./kubectl "${LOCAL_BIN_DIR}/"
        log "      kubectl installed to ${LOCAL_BIN_DIR}/kubectl"
    else
        log "      kubectl found at $(command -v kubectl)"
    fi
    command -v kubectl > /dev/null || error_exit "kubectl not found after installation attempt."
}



# Pre-flight Checks & Setup
log "🎬 Starting Usernetes Control Plane Setup"
log "    Temporary directory: ${TMPDIR}"
mkdir -p "${TMPDIR}"
cd "${TMPDIR}"

if [[ ! -d "${USERNETES_TEMPLATE_PATH}" ]]; then
   error_exit "Usernetes template ${USERNETES_TEMPLATE_PATH} does not exist"
fi

log "    📦 Container technology: ${USERNETES_CONTAINER_TECH}"
export CONTAINER_TECHNOLOGY="${USERNETES_CONTAINER_TECH}"
export CONTAINER_ENGINE="${USERNETES_CONTAINER_TECH}"

# Ensure container software is installed
log "    🔎 Checking for ${USERNETES_CONTAINER_TECH}..."
if ! command -v "${USERNETES_CONTAINER_TECH}" > /dev/null; then
  error_exit "Could not find ${USERNETES_CONTAINER_TECH}. Please ensure it's installed and in PATH."
fi

container_runtime_path=$(command -v "${USERNETES_CONTAINER_TECH}")
log "    Found ${USERNETES_CONTAINER_TECH} at ${container_runtime_path}"

# Install kubectl if not present
log "    👀 Looking for kubectl"
install_kubectl

# Cleanup any previous podman context, setup with vhs
log "    📦 Configuring ${container_runtime_path}"

log "🦋 Setting up Environment for Usernetes"
export XDG_RUNTIME_DIR="${TMPDIR}/.usernetes/runtime"
log "    XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR}"
rm -rf "${XDG_RUNTIME_DIR}" # Clean slate
mkdir -p "${XDG_RUNTIME_DIR}"

setup_podman() {
    # These are likely to give issues. This resets podman with a vfs backend and then
    # cleans up tmp in the unshared context
    if [[ -e "${HOME}/.config/containers/storage.conf" ]]; then
        return    
    fi
    if [[ -x "/collab/usr/gapps/lcweg/containers/scripts/enable-podman.sh" ]]; then
        log "      Running enable-podman.sh vfs"
        if ! bash /collab/usr/gapps/lcweg/containers/scripts/enable-podman.sh overlay; then
            log "      WARNING: enable-podman.sh script failed. Continuing, but podman might not be configured correctly."
        fi
    else
        log "      WARNING: /collab/usr/gapps/lcweg/containers/scripts/enable-podman.sh not found or not executable."
    fi
}
setup_podman

unshare_cleanup() {
    log "      Ensuring buildah is available for unshare..."
    if command -v buildah > /dev/null; then
        log "      Running buildah unshare rm -rf ${TMPDIR}/* (if exists)"
        buildah unshare rm -rf "${TMPDIR}/"* || log "      buildah unshare cleanup command failed, this might be okay if no prior data."
    else
        log "      WARNING: buildah not found. Skipping unshare cleanup."
    fi
}
unshare_cleanup

# Usernetes Specific Setup
log "📂 Copying Usernetes template from ${USERNETES_TEMPLATE_PATH}"
cp -R "${USERNETES_TEMPLATE_PATH}" "${TMPDIR}/usernetes"

 # Now inside the copied template
cd "${TMPDIR}/usernetes"
sleep 3

log "👷 Building Usernetes container image 'usernetes_base'"
${container_runtime_path} build --userns-uid-map=0:0:1 --userns-uid-map=1:1:1999 --userns-uid-map=65534:2000:2 -f $(pwd)/Dockerfile.d/Dockerfile.base -t usernetes_base $(pwd)

log "👷 Building Usernetes container image 'usernetes_node'"
${container_runtime_path} build --userns-uid-map=0:0:1 --userns-uid-map=1:1:1999 --userns-uid-map=65534:2000:2 -f $(pwd)/Dockerfile -t usernetes_node $(pwd)

cleanup() {
    log "🧹 Cleaning up old networks or volumes (best effort)"
    make down-v || log "      'make down-v' failed, possibly because nothing was running. Continuing."


    # Explicit cleanup, as 'make down-v' might not cover everything or could fail
    "${container_runtime_path}" network rm usernetes_default -f || log "      Network 'usernetes_default' not found."
    "${container_runtime_path}" volume rm usernetes_node-var -f || log "      Volume 'usernetes_node-var' not found."
    "${container_runtime_path}" volume rm usernetes_node-opt -f || log "      Volume 'usernetes_node-opt' not found."
    "${container_runtime_path}" volume rm usernetes_node-etc -f || log "      Volume 'usernetes_node-etc' not found."
}
cleanup

log "    ⬆️ Bringing up the Usernetes node(s) with 'make up'"
if ! make up-built; then
    error_exit "Failed to bring up Usernetes with 'make up'."
fi
sleep 3

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
log "To use this cluster from another terminal, set: export KUBECONFIG=${KUBECONFIG}"

# Ensure the kubeconfig is readable by the user
chmod 600 "${KUBECONFIG}"

# The user will likely want to do this.
# source <(kubectl completion bash)
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
log "🏃‍➡️ Copying to ${shared_join_command_dir}"
chmod +x join-command
cp join-command ${shared_join_command_dir}

log "🎉 Usernetes Control Plane setup complete. Kubeconfig is at: ${KUBECONFIG}"
log "🚀 Service will now idle indefinitely. Process ID: $$"

# Make a file to easily source to get environment
cat <<EOF > source_env.sh
#!/bin/bash
export PATH=~/.local/bin:$PATH
export KUBECONFIG=$TMPDIR/usernetes/kubeconfig
export XDG_RUNTIME_DIR=$TMPDIR/.usernetes/runtime
source <(kubectl completion bash)
EOF

# Keep the script running so systemd considers the service active.
# The actual k8s processes are managed by containerd/kubelet inside the usernetes_node container.
sleep infinity
