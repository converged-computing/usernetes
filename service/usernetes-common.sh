#!/bin/bash
#
# Shared setup for the Usernetes control plane and worker user services.
# This file is meant to be sourced by usernetes-start-control-plane.sh and
# usernetes-start-worker.sh, not executed directly.
#
# Everything here can be overridden from the environment (for example with an
# Environment= line in the .service file, or `systemctl --user set-environment`):
#
#   USERNETES_CONTAINER_TECH   Container engine to use (default: podman).
#   USERNETES_TEMPLATE_PATH    Usernetes checkout that is copied to TMPDIR on
#                              each node (default: /usr/workspace/usernetes/usernetes-wip).
#   USERNETES_SHARED_DIR       Shared filesystem where the control plane leaves
#                              the join-command for workers (default: /usr/workspace/usernetes).
#   USERNETES_CNI              CNI passed to make (default: calico).
#   CALICO_VXLAN_IIFNAME       Interface the node's entrypoint matches for inbound
#                              Calico VXLAN packets (default here: lo, for Podman's
#                              rootlessport; upstream default is eth0).
#   USERNETES_RABBIT_MOUNT     Where rabbit (NNF) storage is mounted on each node
#                              (default: /mnt/nnf). Exactly one <uuid>-N directory
#                              is expected under it during an allocation.
#   USERNETES_STORAGE_ROOT     Skip discovery and use this directory as the root
#                              for podman storage. Useful on nodes without a rabbit.
#   USERNETES_STORAGE_DRIVER   containers/storage driver written to storage.conf
#                              (default: vfs).
#   USERNETES_RUNROOT          podman runroot (default: <rabbit>/usernetes/run-<uid>/containers).
#   USERNETES_RUNROOT_SYMLINK  Set to 1 to reference the runroot through a short
#                              symlink ${TMPDIR}/.nnf -> <rabbit>/usernetes. Only
#                              needed if podman rejects the runroot as longer than
#                              50 characters. Off by default: the storage.conf is
#                              then written exactly as a hand-made one.
#
# After sourcing, call usernetes_common_setup <control-plane|worker>. On return
# the current directory is the copied usernetes checkout, the container images
# are built, and stale networks/volumes are cleaned up.

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
}

error_exit() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2
    exit 1
}

# Defaults. LC only supplies podman.
export USERNETES_CONTAINER_TECH="${USERNETES_CONTAINER_TECH:-podman}"
export USERNETES_TEMPLATE_PATH="${USERNETES_TEMPLATE_PATH:-/usr/workspace/usernetes/usernetes-wip}"
export USERNETES_SHARED_DIR="${USERNETES_SHARED_DIR:-/usr/workspace/usernetes}"
export USERNETES_CNI="${USERNETES_CNI:-calico}"
export USERNETES_RABBIT_MOUNT="${USERNETES_RABBIT_MOUNT:-/mnt/nnf}"
export USERNETES_STORAGE_DRIVER="${USERNETES_STORAGE_DRIVER:-vfs}"

# The Makefile reads CNI; keep it consistent for every make call in the services.
export CNI="${USERNETES_CNI}"
# Podman 4.x forwards published ports with rootlessport, which delivers into the
# node container on lo, so the entrypoint's Calico VXLAN source rewrite must
# match lo instead of eth0 (docker-compose.yaml passes this into the node).
export CALICO_VXLAN_IIFNAME="${CALICO_VXLAN_IIFNAME:-lo}"

# Podman build flags. Our subuid range is small, so map what we have.
USERNETES_BUILD_ARGS=(--userns-uid-map=0:0:1 --userns-uid-map=1:1:1999 --userns-uid-map=65534:2000:2)

# Ensure HOME is set (it is not guaranteed under systemd --user on every host)
# and put ~/.local/bin first on the PATH so our podman-compose and kubectl win.
usernetes_setup_home() {
    USERNAME=$(whoami)
    export USERNAME

    if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
        local user_home_dir
        user_home_dir=$(getent passwd "${USERNAME}" | cut -d: -f6)
        if [[ -z "${user_home_dir}" || ! -d "${user_home_dir}" ]]; then
            error_exit "Cannot determine user's home directory. HOME variable is not set or invalid, and getent failed."
        fi
        export HOME="${user_home_dir}"
        log "WARNING: HOME variable was not initially set or valid. Using '${HOME}' from system lookup."
    fi

    LOCAL_BIN_DIR="${HOME}/.local/bin"
    mkdir -p "${LOCAL_BIN_DIR}"
    export PATH="${LOCAL_BIN_DIR}:${PATH}"
    log "    Updated PATH: ${PATH}"

    # Write to /tmp but scoped to the username.
    # We don't want to use /var because that is a memory based fs.
    export TMPDIR="/tmp/${USERNAME}"
    mkdir -p "${TMPDIR}"
    log "    Temporary directory: ${TMPDIR}"
}

usernetes_install_kubectl() {
    log "    👀 Looking for kubectl"
    if ! command -v kubectl > /dev/null; then
        log "      Installing kubectl..."
        curl -sSfLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x ./kubectl
        mv ./kubectl "${LOCAL_BIN_DIR}/"
        log "      kubectl installed to ${LOCAL_BIN_DIR}/kubectl"
    else
        log "      kubectl found at $(command -v kubectl)"
    fi
    command -v kubectl > /dev/null || error_exit "kubectl not found after installation attempt."
}

# Resolve the container engine and (for podman) the compose implementation.
usernetes_check_engine() {
    log "    📦 Container technology: ${USERNETES_CONTAINER_TECH}"
    export CONTAINER_TECHNOLOGY="${USERNETES_CONTAINER_TECH}"
    export CONTAINER_ENGINE="${USERNETES_CONTAINER_TECH}"

    log "    🔎 Checking for ${USERNETES_CONTAINER_TECH}..."
    if ! command -v "${USERNETES_CONTAINER_TECH}" > /dev/null; then
        error_exit "Could not find ${USERNETES_CONTAINER_TECH}. Please ensure it's installed and in PATH."
    fi
    container_runtime_path=$(command -v "${USERNETES_CONTAINER_TECH}")
    log "    Found ${USERNETES_CONTAINER_TECH} at ${container_runtime_path}"

    if [[ "${USERNETES_CONTAINER_TECH}" == "podman" ]]; then
        # Must be our local podman-compose (with the PODMAN_SYSTEMD_UNIT label removed).
        local compose_path
        compose_path=$(command -v podman-compose) || error_exit "podman-compose not found in PATH (expected in ${LOCAL_BIN_DIR})."
        log "    Found podman-compose at ${compose_path}"
    fi
}

# Find the rabbit storage for this node. Each physical node has its own
# ${USERNETES_RABBIT_MOUNT}/<uuid>-N directory, and we expect exactly one.
# Sets and exports USERNETES_STORAGE_ROOT.
usernetes_discover_storage_root() {
    if [[ -n "${USERNETES_STORAGE_ROOT:-}" ]]; then
        log "    💾 Using USERNETES_STORAGE_ROOT from environment: ${USERNETES_STORAGE_ROOT}"
    else
        log "    💾 Looking for rabbit storage under ${USERNETES_RABBIT_MOUNT}"
        if [[ ! -d "${USERNETES_RABBIT_MOUNT}" ]]; then
            error_exit "Rabbit mount ${USERNETES_RABBIT_MOUNT} does not exist on $(hostname). Was the allocation requested with rabbit storage? Set USERNETES_STORAGE_ROOT to use another directory."
        fi
        local candidates=() d
        for d in "${USERNETES_RABBIT_MOUNT}"/*/; do
            [[ -d "${d}" ]] || continue
            candidates+=("${d%/}")
        done
        case "${#candidates[@]}" in
            0)
                error_exit "No rabbit storage directory found under ${USERNETES_RABBIT_MOUNT} on $(hostname). Set USERNETES_STORAGE_ROOT to use another directory."
                ;;
            1)
                USERNETES_STORAGE_ROOT="${candidates[0]}"
                ;;
            *)
                error_exit "Expected exactly one directory under ${USERNETES_RABBIT_MOUNT}, found ${#candidates[@]}: ${candidates[*]}. Set USERNETES_STORAGE_ROOT to pick one."
                ;;
        esac
    fi

    if [[ ! -d "${USERNETES_STORAGE_ROOT}" || ! -w "${USERNETES_STORAGE_ROOT}" ]]; then
        error_exit "Storage root ${USERNETES_STORAGE_ROOT} is not a writable directory."
    fi
    export USERNETES_STORAGE_ROOT
    log "    💾 Storage root: ${USERNETES_STORAGE_ROOT}"
}

# Write a per-node storage.conf onto the rabbit, in a per-node containers
# config directory selected with XDG_CONFIG_HOME. This is the same lookup
# podman uses for ~/.config/containers/storage.conf, so it behaves exactly like
# a hand-made file there. $HOME is shared across nodes, so we never touch it.
#
# Layout under ${USERNETES_STORAGE_ROOT}/usernetes:
#   config/                              XDG_CONFIG_HOME
#   config/containers/storage.conf       generated, byte for byte like a manual one
#   config/containers/*.conf             copied from ~/.config/containers (except storage*.conf)
#   config/containers/storage            graphroot (images, layers, volumes)
#   run-<uid>/containers                 runroot
usernetes_setup_podman_storage() {
    if [[ "${USERNETES_CONTAINER_TECH}" != "podman" ]]; then
        return
    fi
    usernetes_discover_storage_root
    usernetes_write_storage_conf
    usernetes_verify_podman_storage
}

# Compute the layout from USERNETES_STORAGE_ROOT and write storage.conf.
# Exports XDG_CONFIG_HOME, USERNETES_STORAGE_CONF, USERNETES_RUNROOT, USERNETES_GRAPHROOT.
usernetes_write_storage_conf() {
    local storage_dir="${USERNETES_STORAGE_ROOT}/usernetes"
    local config_home="${storage_dir}/config"
    export USERNETES_RUNROOT="${USERNETES_RUNROOT:-${storage_dir}/run-$(id -u)/containers}"
    export USERNETES_GRAPHROOT="${config_home}/containers/storage"
    export USERNETES_STORAGE_CONF="${config_home}/containers/storage.conf"
    mkdir -p "${USERNETES_RUNROOT}" "${USERNETES_GRAPHROOT}"

    # Optional: podman 4.x refuses a runroot string longer than 50 characters
    # (pkg/domain/infra/runtime_libpod.go). Reach the same directory on the
    # rabbit through a short symlink under TMPDIR instead.
    if [[ "${USERNETES_RUNROOT_SYMLINK:-0}" == "1" && "${#USERNETES_RUNROOT}" -gt 50 && "${USERNETES_RUNROOT}" == "${storage_dir}/"* ]]; then
        local link="${TMPDIR}/.nnf"
        if [[ -e "${link}" && ! -L "${link}" ]]; then
            error_exit "${link} exists and is not a symlink; remove it so it can point at ${storage_dir}."
        fi
        mkdir -p "${TMPDIR}"
        ln -sfn "${storage_dir}" "${link}"
        local short="${link}/${USERNETES_RUNROOT#"${storage_dir}"/}"
        log "    🔗 runroot ${USERNETES_RUNROOT} is ${#USERNETES_RUNROOT} characters; using ${short} via symlink ${link}"
        USERNETES_RUNROOT="${short}"
        [[ -d "${USERNETES_RUNROOT}" ]] || error_exit "runroot ${USERNETES_RUNROOT} is not a directory (symlink ${link} broken?)"
    fi

    # Keep the user's other containers config (containers.conf, registries.conf, ...)
    # visible under the new XDG_CONFIG_HOME. storage*.conf variants are skipped
    # on purpose: the generated one below is the only storage.conf here.
    local f
    for f in "${HOME}"/.config/containers/*; do
        [[ -e "${f}" ]] || continue
        [[ "$(basename "${f}")" == storage*.conf ]] && continue
        [[ -e "${config_home}/containers/$(basename "${f}")" ]] || cp -a "${f}" "${config_home}/containers/"
    done

    log "    📝 Writing ${USERNETES_STORAGE_CONF} (driver ${USERNETES_STORAGE_DRIVER})"
    cat <<EOF > "${USERNETES_STORAGE_CONF}"
[storage]
  driver = "${USERNETES_STORAGE_DRIVER}"
  runroot = "${USERNETES_RUNROOT}"
  graphroot = "${USERNETES_GRAPHROOT}"
[storage.options.${USERNETES_STORAGE_DRIVER}]
  ignore_chown_errors = "true"
EOF
    export XDG_CONFIG_HOME="${config_home}"
    # Make sure nothing else redirects podman away from the file we just wrote.
    unset CONTAINERS_STORAGE_CONF
}

# Confirm podman actually picked the file up before we build anything on it.
# Keep stderr: if podman cannot start with this config we want the reason in the log.
usernetes_verify_podman_storage() {
    local seen rc=0 conf graph
    seen=$("${container_runtime_path}" info --format '{{.Store.ConfigFile}}|{{.Store.GraphRoot}}' 2>&1) || rc=$?
    IFS='|' read -r conf graph <<<"${seen}"
    if [[ "${rc}" != "0" || "${conf}" != "${USERNETES_STORAGE_CONF}" || "${graph}" != "${USERNETES_GRAPHROOT}" ]]; then
        log "      podman info exited ${rc}. Output:"
        printf '%s\n' "${seen}" | sed 's/^/        | /'
        log "      Reproduce with:"
        log "        export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"
        log "        ${container_runtime_path} info"
        log "      Or run the debug script: $(dirname "${BASH_SOURCE[0]}")/debug-storage.sh"
        error_exit "podman is not using the rabbit storage: expected config ${USERNETES_STORAGE_CONF} and graphroot ${USERNETES_GRAPHROOT}. See the output above."
    fi
    log "    ✅ podman config:    ${USERNETES_STORAGE_CONF}"
    log "    ✅ podman graphroot: ${USERNETES_GRAPHROOT}"
    log "    ✅ podman runroot:   ${USERNETES_RUNROOT}"
}

# Fresh XDG_RUNTIME_DIR for the rootless engine (pause process, sockets).
usernetes_reset_runtime_dir() {
    export XDG_RUNTIME_DIR="${TMPDIR}/.usernetes/runtime"
    log "    XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR}"
    rm -rf "${XDG_RUNTIME_DIR}" # Clean slate, sweep sweep!
    mkdir -p "${XDG_RUNTIME_DIR}"
}

# Remove leftovers in TMPDIR from a previous run, inside the user namespace so
# files owned by mapped uids can be deleted too. Dotfiles (.usernetes) survive.
usernetes_unshare_cleanup() {
    log "      Ensuring buildah is available for unshare..."
    if command -v buildah > /dev/null; then
        log "      Running buildah unshare rm -rf ${TMPDIR}/* (if exists)"
        buildah unshare rm -rf "${TMPDIR}/"* || log "      buildah unshare cleanup command failed, this might be okay if no prior data."
    else
        log "      WARNING: buildah not found. Skipping unshare cleanup."
    fi
}

# Copy the usernetes checkout to this node and cd into it.
usernetes_copy_template() {
    if [[ ! -d "${USERNETES_TEMPLATE_PATH}" ]]; then
        error_exit "Usernetes template ${USERNETES_TEMPLATE_PATH} does not exist"
    fi
    log "📂 Copying Usernetes template from ${USERNETES_TEMPLATE_PATH}"
    cp -R "${USERNETES_TEMPLATE_PATH}" "${TMPDIR}/usernetes"
    cd "${TMPDIR}/usernetes"
    sleep 3
}

# Write source_env.sh into the copied checkout so an interactive shell can use
# the same podman storage, runtime dir, and (on the control plane) kubectl.
# Argument: control-plane or worker.
usernetes_write_source_env() {
    local role="$1"
    local target="${TMPDIR}/usernetes/source_env.sh"
    log "    📝 Writing ${target}"
    cat <<EOF > "${target}"
#!/bin/bash
# Generated by usernetes-start-${role}.sh on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S').
# Source this file to use podman, make, and kubectl against this node's cluster.
export PATH="\${HOME}/.local/bin:\${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
export CONTAINER_ENGINE="${CONTAINER_ENGINE}"
export CNI="${CNI}"
export CALICO_VXLAN_IIFNAME="${CALICO_VXLAN_IIFNAME}"
EOF
    if [[ -n "${USERNETES_STORAGE_ROOT:-}" ]]; then
        cat <<EOF >> "${target}"
# Podman storage lives on this node's rabbit, not in \$HOME.
# XDG_CONFIG_HOME selects the per-node containers config (storage.conf) there.
export USERNETES_STORAGE_ROOT="${USERNETES_STORAGE_ROOT}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME}"
unset CONTAINERS_STORAGE_CONF
EOF
    fi
    if [[ "${role}" == "control-plane" ]]; then
        cat <<EOF >> "${target}"
export KUBECONFIG="${TMPDIR}/usernetes/kubeconfig"
source <(kubectl completion bash)
EOF
    fi
}

usernetes_build_images() {
    log "👷 Building Usernetes container image 'usernetes_base'"
    "${container_runtime_path}" build "${USERNETES_BUILD_ARGS[@]}" -f "$(pwd)/Dockerfile.d/Dockerfile.base" -t usernetes_base "$(pwd)"

    log "👷 Building Usernetes container image 'usernetes_node'"
    "${container_runtime_path}" build "${USERNETES_BUILD_ARGS[@]}" -f "$(pwd)/Dockerfile" -t usernetes_node "$(pwd)"
}

usernetes_cleanup_stale() {
    log "🧹 Cleaning up old networks or volumes (best effort)"
    make down-v || log "      'make down-v' failed, possibly because nothing was running. Continuing."

    # Explicit cleanup, as 'make down-v' might not cover everything or could fail
    "${container_runtime_path}" network rm usernetes_default -f || log "      Network 'usernetes_default' not found."
    "${container_runtime_path}" volume rm usernetes_node-var -f || log "      Volume 'usernetes_node-var' not found."
    "${container_runtime_path}" volume rm usernetes_node-opt -f || log "      Volume 'usernetes_node-opt' not found."
    "${container_runtime_path}" volume rm usernetes_node-etc -f || log "      Volume 'usernetes_node-etc' not found."
}

# rp_filter fixup inside the node container. Call after `make up-built` and
# again after kubeadm init/join, and it is idempotent.
#
# With CALICO_VXLAN_IIFNAME=lo the entrypoint rewrites the source of inbound
# VXLAN packets on lo to Felix's sentinel address 169.254.7.115. Such a packet
# fails strict reverse-path filtering (its only route is the default via eth0),
# so rp_filter has to be loose. The entrypoint sets that at boot, but on hetchy
# it was back at 1 by the time Calico ran, so set it live, persist it in
# sysctl.d for systemd-sysctl, and log the values found before re-applying so
# the reset can be seen. The effective rp_filter is max(all, interface), so
# "all" covers vxlan.calico once Calico creates it.
usernetes_node_vxlan_fixups() {
    if [[ "${CNI}" != "calico" ]]; then
        return
    fi
    local compose port
    compose=$(./Makefile.d/detect-container-engine.sh COMPOSE)
    port="${PORT_CALICO:-4789}"
    log "🩹 Applying rp_filter fixup inside the node container"
    ${compose} exec -T node bash -c "
        echo \"rp_filter before: all=\$(cat /proc/sys/net/ipv4/conf/all/rp_filter) default=\$(cat /proc/sys/net/ipv4/conf/default/rp_filter) lo=\$(cat /proc/sys/net/ipv4/conf/lo/rp_filter) eth0=\$(cat /proc/sys/net/ipv4/conf/eth0/rp_filter)\"
        for f in all default lo eth0 vxlan.calico; do [ -e /proc/sys/net/ipv4/conf/\$f/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/\$f/rp_filter; done
        printf 'net.ipv4.conf.all.rp_filter = 2\\nnet.ipv4.conf.default.rp_filter = 2\\n' > /etc/sysctl.d/99-usernetes.conf
        echo \"rp_filter after:  all=\$(cat /proc/sys/net/ipv4/conf/all/rp_filter) default=\$(cat /proc/sys/net/ipv4/conf/default/rp_filter) lo=\$(cat /proc/sys/net/ipv4/conf/lo/rp_filter) eth0=\$(cat /proc/sys/net/ipv4/conf/eth0/rp_filter)\"
        echo \"entrypoint prerouting rule: \$(nft list chain ip u7s-calico-vxlan prerouting | grep 'ip saddr set' | sed 's/^ *//')\"
    " 2>&1 | grep -vE "^(podman-compose version|\['podman'|using podman version|podman exec |exit code: 0)" | sed 's/^/      /' \
        || log "      WARNING: rp_filter fixup failed; cross-node pod traffic may not work. Run service/check-vxlan.sh"
}

# Everything both roles do before the role-specific kubeadm steps.
# Argument: control-plane or worker.
usernetes_common_setup() {
    local role="$1"

    log "🎬 Starting Usernetes ${role} setup on $(hostname)"
    usernetes_setup_home
    cd "${TMPDIR}"

    usernetes_check_engine
    usernetes_install_kubectl

    log "🦋 Setting up Environment for Usernetes"
    usernetes_reset_runtime_dir
    usernetes_setup_podman_storage
    usernetes_unshare_cleanup

    usernetes_copy_template
    usernetes_write_source_env "${role}"

    usernetes_build_images
    usernetes_cleanup_stale
}
