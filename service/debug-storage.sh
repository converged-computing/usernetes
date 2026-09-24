#!/bin/bash
#
# Exercise the rabbit-backed podman storage on one node, without starting the
# service. Does exactly what the service does (discover the rabbit, write
# storage.conf into a per-node config dir, export XDG_CONFIG_HOME and
# XDG_RUNTIME_DIR) and then
# drives podman through real operations with that config, checking after each
# one that the data landed on the rabbit. Deep diagnostics (namespaces, strace,
# debug log, stale databases) are printed only when a step fails.
#
# Usage (on a compute node, in the allocation):
#   /usr/workspace/usernetes/service/debug-storage.sh [options]
#
#   --fresh     Wipe the runtime dir (XDG_RUNTIME_DIR) first, exactly like the
#               service does. Default is to leave it, so stale state is visible.
#   --migrate   Run `podman system migrate` first. Replaces the pause process,
#               which is needed when it was created before the rabbit was mounted.
#   --pull      Also pull docker.io/library/busybox and run a container from it.
#   --keep      Leave the test image and volume in place instead of removing them.
#   --reset     Run `podman system reset --force` against the rabbit storage
#               first. Destroys images, containers, and volumes on the rabbit only.
#
# Any USERNETES_* variable honoured by usernetes-common.sh can be set in the
# environment, e.g. USERNETES_STORAGE_ROOT=/tmp/$USER/fake-rabbit.

set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=usernetes-common.sh
source "${here}/usernetes-common.sh"

fresh=0 migrate=0 pull=0 keep=0 reset=0
for arg in "$@"; do
    case "${arg}" in
        --fresh) fresh=1 ;;
        --migrate) migrate=1 ;;
        --pull) pull=1 ;;
        --keep) keep=1 ;;
        --reset) reset=1 ;;
        -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) error_exit "Unknown option: ${arg}" ;;
    esac
done

failures=0
section() { echo; echo "=== $1"; }
ok()      { echo "  ✅ $1"; }
bad()     { echo "  ❌ $1"; failures=$((failures + 1)); }
warn()    { echo "  ⚠️  $1"; }
show()    { sed 's/^/    | /'; }
# run <description> <command...>: run a podman step, show its output, record pass/fail.
run() {
    local desc="$1"; shift
    echo "  \$ $*"
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    [[ -n "${out}" ]] && printf '%s\n' "${out}" | show
    if [[ "${rc}" == "0" ]]; then ok "${desc}"; else bad "${desc} (exit ${rc})"; fi
    return "${rc}"
}
on_rabbit() { # on_rabbit <path>: true if the resolved path is under the rabbit storage root
    [[ "$(readlink -f "$1" 2>/dev/null)" == "$(readlink -f "${USERNETES_STORAGE_ROOT}")"/* ]]
}

# 1. Environment and rabbit -------------------------------------------------
section "Environment"
usernetes_setup_home >/dev/null
container_runtime_path=$(command -v podman) || error_exit "podman not found"
echo "  host:     $(hostname)   user: ${USERNAME} (uid $(id -u))   kernel: $(uname -r)"
echo "  podman:   ${container_runtime_path} ($(podman --version 2>&1))"
echo "  HOME:     ${HOME}   TMPDIR: ${TMPDIR}"
grep -q "^${USERNAME}:" /etc/subuid 2>/dev/null || warn "no /etc/subuid entry for ${USERNAME} (ignore_chown_errors is set, so this may be fine)"

section "Rabbit discovery (${USERNETES_RABBIT_MOUNT})"
[[ -d "${USERNETES_RABBIT_MOUNT}" ]] && ls -la "${USERNETES_RABBIT_MOUNT}" | show
usernetes_discover_storage_root || exit 1
findmnt -T "${USERNETES_STORAGE_ROOT}" -o TARGET,FSTYPE,OPTIONS 2>/dev/null | show
df -h "${USERNETES_STORAGE_ROOT}" | tail -1 | show

# 2. Same environment as the service ------------------------------------------
section "Environment the service uses"
export XDG_RUNTIME_DIR="${TMPDIR}/.usernetes/runtime"
if [[ "${fresh}" == "1" ]]; then
    echo "  --fresh: wiping ${XDG_RUNTIME_DIR}"
    rm -rf "${XDG_RUNTIME_DIR:?}"
fi
mkdir -p "${XDG_RUNTIME_DIR}"
usernetes_write_storage_conf || exit 1
echo "  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
echo "  export XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"
echo "  ${USERNETES_STORAGE_CONF}:"
show < "${USERNETES_STORAGE_CONF}"
echo "  other files in ${XDG_CONFIG_HOME}/containers: $(ls "${XDG_CONFIG_HOME}/containers" | grep -v '^storage' | tr '\n' ' ')"
echo "  runroot string is ${#USERNETES_RUNROOT} chars (limit 50), resolves to $(readlink -f "${USERNETES_RUNROOT}")"

if [[ "${migrate}" == "1" ]]; then
    run "podman system migrate" podman system migrate
fi
if [[ "${reset}" == "1" ]]; then
    run "podman system reset" podman system reset --force
fi

# 3. Drive podman with that config ---------------------------------------------
section "Step 1: podman reads the config"
seen=$(podman info --format '{{.Store.ConfigFile}}|{{.Store.GraphDriverName}}|{{.Store.GraphRoot}}|{{.Store.RunRoot}}' 2>&1); rc=$?
IFS='|' read -r s_conf s_driver s_graph s_run <<<"${seen}"
if [[ "${rc}" != "0" ]]; then
    printf '%s\n' "${seen}" | show
    bad "podman info failed (exit ${rc})"
else
    echo "  config file: ${s_conf}"
    echo "  driver:      ${s_driver}"
    echo "  graphroot:   ${s_graph}"
    echo "  runroot:     ${s_run}"
    [[ "${s_conf}" == "${USERNETES_STORAGE_CONF}" ]] && ok "podman is reading our storage.conf" || bad "podman is reading ${s_conf:-<nothing>}, not ${USERNETES_STORAGE_CONF}"
    [[ "${s_graph}" == "${USERNETES_GRAPHROOT}" ]] && ok "graphroot is on the rabbit" || bad "graphroot is ${s_graph:-<empty>}, expected ${USERNETES_GRAPHROOT}"
    [[ "${s_run}" == "${USERNETES_RUNROOT}" ]] && ok "runroot is ${USERNETES_RUNROOT}" || bad "runroot is ${s_run:-<empty>}, expected ${USERNETES_RUNROOT}"
    [[ "${s_driver}" == "${USERNETES_STORAGE_DRIVER}" ]] && ok "driver is ${USERNETES_STORAGE_DRIVER}" || bad "driver is ${s_driver:-<empty>}, expected ${USERNETES_STORAGE_DRIVER}"
fi

if [[ "${failures}" == "0" ]]; then
    section "Step 2: list images (exercises the libpod database on the rabbit)"
    run "podman images" podman images
    [[ -e "${USERNETES_GRAPHROOT}/libpod/db.sql" || -e "${USERNETES_GRAPHROOT}/libpod/bolt_state.db" ]] \
        && ok "libpod database created under ${USERNETES_GRAPHROOT}/libpod" \
        || warn "no libpod database under ${USERNETES_GRAPHROOT}/libpod yet"

    section "Step 3: create a volume (compose volumes node-var/opt/etc live here)"
    vol="u7s-debug-$$"
    if run "podman volume create" podman volume create "${vol}"; then
        mp=$(podman volume inspect "${vol}" --format '{{.Mountpoint}}' 2>&1)
        echo "  mountpoint: ${mp}"
        on_rabbit "${mp}" && ok "volume data is on the rabbit" || bad "volume data is NOT on the rabbit"
        echo "hello" > "${mp}/hello" 2>/dev/null && ok "can write into the volume" || warn "cannot write into the volume from the host (expected with subuid mapping)"
        [[ "${keep}" == "1" ]] || run "podman volume rm" podman volume rm "${vol}" >/dev/null
    fi

    section "Step 4: import an image (no registry needed)"
    img="localhost/u7s-debug:$$"
    work=$(mktemp -d "${TMPDIR}/u7s-debug.XXXXXX")
    echo "hello from $(hostname)" > "${work}/hello"
    tar -C "${work}" -cf "${work}/rootfs.tar" hello
    if run "podman import" podman import --quiet "${work}/rootfs.tar" "${img}"; then
        run "podman image exists" podman image exists "${img}"
        layers=$(find "${USERNETES_GRAPHROOT}/${USERNETES_STORAGE_DRIVER}" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
        [[ "${layers}" -gt 0 ]] && ok "${layers} layer(s) under ${USERNETES_GRAPHROOT}/${USERNETES_STORAGE_DRIVER}" || bad "no layers under ${USERNETES_GRAPHROOT}/${USERNETES_STORAGE_DRIVER}"
        run "podman image inspect" podman image inspect "${img}" --format 'size={{.Size}} layers={{len .RootFS.Layers}}'
        [[ "${keep}" == "1" ]] || run "podman rmi" podman rmi "${img}" >/dev/null
    fi

    section "Step 5: build an image with the service's userns flags (FROM scratch, no pull)"
    printf 'FROM scratch\nCOPY hello /hello\n' > "${work}/Dockerfile"
    bimg="localhost/u7s-debug-build:$$"
    if run "podman build" podman build "${USERNETES_BUILD_ARGS[@]}" --quiet -t "${bimg}" "${work}"; then
        run "podman image exists" podman image exists "${bimg}"
        [[ "${keep}" == "1" ]] || run "podman rmi" podman rmi "${bimg}" >/dev/null
    fi
    rm -rf "${work:?}"

    if [[ "${pull}" == "1" ]]; then
        section "Step 6: pull and run busybox (--pull)"
        if run "podman pull" podman pull --quiet docker.io/library/busybox:latest; then
            run "podman run" podman run --rm docker.io/library/busybox:latest sh -c 'echo "container says hello from $(hostname)"; df -h /'
            [[ "${keep}" == "1" ]] || run "podman rmi" podman rmi docker.io/library/busybox:latest >/dev/null
        fi
    fi

    section "What is on the rabbit now"
    du -sh "${USERNETES_GRAPHROOT}" "$(readlink -f "${USERNETES_RUNROOT}")" 2>/dev/null | show
    ls -la "${USERNETES_GRAPHROOT}" 2>/dev/null | show
fi

# 4. Deep diagnostics, only when something failed ------------------------------
if [[ "${failures}" != "0" ]]; then
    section "DIAGNOSTICS: can podman's namespace see the rabbit?"
    # Rootless podman joins the user+mount namespace of its pause process. If that
    # namespace was created before the rabbit was mounted, /mnt/nnf/<uuid> does not
    # exist inside it, storage.conf cannot be read, and podman silently falls back
    # to default storage in $HOME.
    echo "  this shell's mount ns:   $(readlink /proc/self/ns/mnt)"
    for pid in $(pgrep -u "$(id -u)" -x catatonit); do
        echo "  pause process ${pid} mount ns: $(readlink "/proc/${pid}/ns/mnt" 2>&1)  started $(ps -o lstart= -p "${pid}")"
        if [[ -d "/proc/${pid}/root/${USERNETES_STORAGE_ROOT}" ]]; then
            ok "pause ${pid} can see ${USERNETES_STORAGE_ROOT}"
        else
            bad "pause ${pid} cannot see ${USERNETES_STORAGE_ROOT} (mount namespace predates the rabbit mount; rerun with --migrate)"
        fi
    done
    if out=$(podman unshare cat "${USERNETES_STORAGE_CONF}" 2>&1); then
        ok "podman unshare can read storage.conf on the rabbit"
    else
        bad "podman unshare cannot read storage.conf: ${out}"
    fi
    if [[ -f "${XDG_RUNTIME_DIR}/libpod/tmp/pause.pid" ]]; then
        echo "  pause.pid in our runtime dir: $(cat "${XDG_RUNTIME_DIR}/libpod/tmp/pause.pid")"
    fi
    echo "  podman-related processes:"
    pgrep -u "$(id -u)" -a -f 'podman|conmon|catatonit|slirp4netns|pasta' | show || echo "    (none)"

    section "DIAGNOSTICS: podman --log-level=debug info"
    podman --log-level=debug info 2>&1 | grep -vE 'level=debug msg="(Loading registries|Found credentials|Adding|Using conmon)' | show

    if command -v strace >/dev/null; then
        section "DIAGNOSTICS: config and database files podman opens (strace)"
        strace -f -qq -e trace=openat,stat,newfstatat,statx -o "${TMPDIR}/podman-strace.log" podman info >/dev/null 2>&1 || true
        grep -E 'storage\.conf|containers\.conf|db\.sql|bolt_state|/mnt/nnf' "${TMPDIR}/podman-strace.log" | sed 's/^[0-9]* *//' | sort -u | show
        echo "  (full trace in ${TMPDIR}/podman-strace.log)"
    fi

    section "DIAGNOSTICS: other storage config podman might be reading"
    for f in "${HOME}"/.config/containers/storage.conf /etc/containers/storage.conf /etc/containers/containers.conf "${HOME}"/.config/containers/containers.conf; do
        [[ -f "${f}" ]] || continue
        echo "  ${f}:"; grep -vE '^\s*(#|$)' "${f}" | show
    done
    db="${HOME}/.local/share/containers/storage/libpod/db.sql"
    if [[ -f "${db}" ]]; then
        echo "  stale libpod database in default \$HOME graphroot: ${db}"
        python3 - "${db}" <<'EOF' 2>&1 | show
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
print("DBConfig:", [tuple(r) for r in db.execute("select * from DBConfig")])
EOF
    fi

    section "DIAGNOSTICS: explicit --root/--runroot (bypasses storage.conf discovery)"
    podman --root "${USERNETES_GRAPHROOT}" --runroot "${USERNETES_RUNROOT}" --storage-driver "${USERNETES_STORAGE_DRIVER}" info --format '{{.Store.GraphRoot}}' 2>&1 | show
fi

section "Summary"
if [[ "${failures}" == "0" ]]; then
    ok "podman works against the rabbit storage. To use it from a shell:"
    echo "    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
    echo "    export XDG_CONFIG_HOME=${XDG_CONFIG_HOME}"
    exit 0
fi
bad "${failures} failure(s) above"
exit 1
