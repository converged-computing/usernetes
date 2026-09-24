#!/bin/bash
#
# Local tests for usernetes-common.sh and the start scripts. Runs anywhere:
# podman, buildah, make, kubectl and podman-compose are replaced with stubs
# and a fake rabbit mount is created under a temp dir. No cluster is needed.
#
#   ./service/test-common.sh          # run all tests
#   ./service/test-common.sh -v       # also show the captured script logs

set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
verbose=0; [[ "${1:-}" == "-v" ]] && verbose=1

T=$(mktemp -d) || exit 1
trap 'rm -rf "${T:?}"' EXIT
pass=0 fail=0
ok()   { echo "  PASS $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL $1"; fail=$((fail + 1)); }
not_grep() { ! grep -q "$@"; }
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi
}

# --- stubs ------------------------------------------------------------------
mkdir -p "${T}/bin" "${T}/home/.local/bin" "${T}/shared" "${T}/nnf"
cat > "${T}/bin/podman" <<'EOF'
#!/bin/bash
# Stub podman. Reads driver/graphroot/runroot from $XDG_CONFIG_HOME/containers/storage.conf
# like real podman does for rootless users, and fakes the on-disk side effects
# the scripts check for. Fails every call when PODMAN_STUB_FAIL is set.
if [[ -n "${PODMAN_STUB_FAIL:-}" ]]; then echo "Error: ${PODMAN_STUB_FAIL}" >&2; exit 125; fi
conf="${XDG_CONFIG_HOME:-$HOME/.config}/containers/storage.conf"; [[ -f "${conf}" ]] || conf=/dev/null
val() { grep -oP "^\s*$1 = \"\K[^\"]+" "${conf}"; }
graphroot=$(val graphroot); runroot=$(val runroot); driver=$(val driver)
while [[ "${1:-}" == --* ]]; do   # global flags like --root/--runroot/--log-level
    case "$1" in --version) echo "podman version 0.0-stub"; exit 0 ;; --root) graphroot="$2"; shift ;; --runroot|--storage-driver|--log-level) shift ;; esac
    shift
done
case "${1:-}" in
  info)
    mkdir -p "${graphroot}/libpod" && touch "${graphroot}/libpod/db.sql"
    fmt=""; [[ "${2:-}" == --format ]] && fmt="$3"
    fmt="${fmt//\{\{.Store.ConfigFile\}\}/${conf}}"; fmt="${fmt//\{\{.Store.GraphDriverName\}\}/${driver}}"
    fmt="${fmt//\{\{.Store.GraphRoot\}\}/${graphroot}}"; fmt="${fmt//\{\{.Store.RunRoot\}\}/${runroot}}"
    echo "${fmt:-store: stub}" ;;
  images) echo "REPOSITORY TAG IMAGE ID CREATED SIZE" ;;
  volume)
    case "$2" in
      create) mkdir -p "${graphroot}/volumes/$3/_data"; echo "$3" ;;
      inspect) echo "${graphroot}/volumes/$3/_data" ;;
      rm) rm -rf "${graphroot:?}/volumes/$3"; echo "$3" ;;
    esac ;;
  import|build) mkdir -p "${graphroot}/${driver}/stub-layer"; echo "sha256:stub" ;;
  image) [[ "$2" == inspect ]] && echo "size=1 layers=1"; exit 0 ;;
  rmi|pull|run|system) echo "podman $*" ;;
  unshare) shift; exec "$@" ;;
  *) echo "podman $*" ;;
esac
EOF
cat > "${T}/bin/kubectl" <<'EOF'
#!/bin/bash
case "$*" in
  *"get nodes -l"*) echo u7s-testnode ;;
  *completion*) echo "# completion" ;;
  *) echo "kubectl $*" ;;
esac
EOF
cat > "${T}/bin/make" <<'EOF'
#!/bin/bash
echo "make $* CNI=${CNI:-unset} QUICK=${QUICK:-unset} STORAGE=${XDG_CONFIG_HOME:-unset} PWD=$PWD"
[[ "$1" == "join-command" ]] && printf 'echo "10.0.0.5  u7s-cp" >/etc/hosts.u7s\nkubeadm join stub\n' > join-command
[[ "$1" == "kubeconfig" ]] && echo "stub kubeconfig" > kubeconfig
[[ "$1" == "kubeadm-join" ]] && cat join-command
exit 0
EOF
printf '#!/bin/bash\necho "podman-compose $*"\n' > "${T}/bin/podman-compose"
# buildah unshare <cmd> really runs <cmd>, so the TMPDIR cleanup between roles happens.
printf '#!/bin/bash\nif [[ "$1" == unshare ]]; then shift; exec "$@"; fi\necho "buildah $*"\n' > "${T}/bin/buildah"
printf '#!/bin/bash\n[[ -n "${CURL_STUB_FAIL:-}" ]] && exit 7; echo "{}"\n' > "${T}/bin/curl"
chmod +x "${T}/bin/"*
cp "${T}/bin/podman-compose" "${T}/home/.local/bin/"

# The scripts derive TMPDIR from the username; point it into the sandbox instead.
sed "s#export TMPDIR=\"/tmp/\${USERNAME}\"#export TMPDIR=\"${T}/tmp\"#" "${here}/usernetes-common.sh" > "${T}/usernetes-common.sh"
grep -q "${T}/tmp" "${T}/usernetes-common.sh" || { echo "could not patch TMPDIR in test copy"; exit 1; }
cp "${here}/usernetes-start-control-plane.sh" "${here}/usernetes-start-worker.sh" "${here}/debug-storage.sh" "${T}/"

# Run a bash snippet with the stub environment. Extra env as KEY=VALUE args before the snippet.
in_sandbox() {
    local envs=()
    while [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do envs+=("$1"); shift; done
    env -i PATH="${T}/bin:/usr/bin:/bin" HOME="${T}/home" \
        USERNETES_RABBIT_MOUNT="${T}/nnf" USERNETES_SHARED_DIR="${T}/shared" USERNETES_TEMPLATE_PATH="${here}/.." \
        "${envs[@]}" bash -c "$1"
}
# Source the common file in the sandbox and run the given snippet.
fn() {
    local envs=()
    while [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do envs+=("$1"); shift; done
    in_sandbox "${envs[@]}" "set -euo pipefail; source '${T}/usernetes-common.sh'; container_runtime_path='${T}/bin/podman'; export XDG_RUNTIME_DIR='${T}/xdg'; export TMPDIR=\"\${TMPDIR:-${T}/tmp}\"; $*"
}
rabbit="${T}/nnf/aaa26e9d-9490-47da-bdc7-700bb1e89fca-0"
conf="${rabbit}/usernetes/config/containers/storage.conf"

echo "== discovery"
out=$(fn usernetes_discover_storage_root 2>&1); rc=$?
check "zero dirs is an error"                 test "${rc}" != 0
check "zero dirs message mentions the mount"  grep -q "No rabbit storage directory found under ${T}/nnf" <<<"${out}"

mkdir "${rabbit}"
out=$(fn 'usernetes_discover_storage_root; echo "ROOT=$USERNETES_STORAGE_ROOT"' 2>&1); rc=$?
check "one dir succeeds"                      test "${rc}" == 0
check "one dir picks the uuid directory"      grep -q "ROOT=${rabbit}$" <<<"${out}"

touch "${T}/nnf/not-a-dir"
out=$(fn 'usernetes_discover_storage_root; echo "ROOT=$USERNETES_STORAGE_ROOT"' 2>&1); rc=$?
check "plain files under the mount are ignored" test "${rc}" == 0
rm -f "${T:?}/nnf/not-a-dir"

mkdir "${T}/nnf/bbbbbbbb-0000-0000-0000-000000000000-0"
out=$(fn usernetes_discover_storage_root 2>&1); rc=$?
check "two dirs is an error"                  test "${rc}" != 0
check "two dirs message lists both"           grep -q "found 2: .*aaa26e9d.* .*bbbbbbbb" <<<"${out}"
rmdir "${T:?}/nnf/bbbbbbbb-0000-0000-0000-000000000000-0"

mkdir -p "${T}/override"
out=$(fn USERNETES_STORAGE_ROOT="${T}/override" 'usernetes_discover_storage_root; echo "ROOT=$USERNETES_STORAGE_ROOT"' 2>&1)
check "USERNETES_STORAGE_ROOT bypasses discovery" grep -q "ROOT=${T}/override$" <<<"${out}"
out=$(fn USERNETES_STORAGE_ROOT="${T}/does-not-exist" usernetes_discover_storage_root 2>&1); rc=$?
check "non-existent override is an error"     test "${rc}" != 0
mkdir -p "${T}/ro"; chmod 500 "${T}/ro"
out=$(fn USERNETES_STORAGE_ROOT="${T}/ro" usernetes_discover_storage_root 2>&1); rc=$?
check "read-only override is an error"        test "${rc}" != 0
chmod 700 "${T}/ro"

echo "== storage.conf"
out=$(fn 'usernetes_setup_podman_storage; cat "$USERNETES_STORAGE_CONF"; echo "XDG=$XDG_CONFIG_HOME CSC=${CONTAINERS_STORAGE_CONF:-unset}"' 2>&1); rc=$?
check "setup succeeds with stub podman"       test "${rc}" == 0
check "storage.conf written on the rabbit"    test -f "${conf}"
check "XDG_CONFIG_HOME points at the rabbit config dir" grep -q "XDG=${rabbit}/usernetes/config " <<<"${out}"
check "CONTAINERS_STORAGE_CONF is not set"    grep -q "CSC=unset" <<<"${out}"
check "file has exactly the six expected lines" test "$(wc -l < "${conf}")" == 6
check "no comments or extras in the file"     not_grep -vE '^(\[storage\]|  driver = "vfs"|  runroot = ".*"|  graphroot = ".*"|\[storage.options.vfs\]|  ignore_chown_errors = "true")$' "${conf}"
check "driver is vfs"                         grep -q '^  driver = "vfs"$' "${conf}"
check "runroot is the plain rabbit path"      grep -q "^  runroot = \"${rabbit}/usernetes/run-$(id -u)/containers\"$" "${conf}"
check "no symlink created by default"         test ! -e "${T}/tmp/.nnf"
check "graphroot under config/containers"     grep -q "^  graphroot = \"${rabbit}/usernetes/config/containers/storage\"$" "${conf}"
check "ignore_chown_errors under vfs options" bash -c "grep -A1 '^\[storage.options.vfs\]' '${conf}' | grep -q 'ignore_chown_errors = \"true\"'"
check "runroot directory created on rabbit"   test -d "${rabbit}/usernetes/run-$(id -u)/containers"
check "graphroot directory created"           test -d "${rabbit}/usernetes/config/containers/storage"
mkdir -p "${T}/short-run"
out=$(fn USERNETES_RUNROOT="${T}/short-run" 'usernetes_setup_podman_storage; cat "$USERNETES_STORAGE_CONF"' 2>&1)
check "USERNETES_RUNROOT override is honoured" grep -q "^  runroot = \"${T}/short-run\"$" <<<"${out}"
echo "== runroot symlink (opt-in)"
out=$(fn USERNETES_RUNROOT_SYMLINK=1 'usernetes_setup_podman_storage; cat "$USERNETES_STORAGE_CONF"' 2>&1); rc=$?
check "symlink mode succeeds"                 test "${rc}" == 0
check "runroot goes through the short symlink" grep -q "^  runroot = \"${T}/tmp/.nnf/run-$(id -u)/containers\"$" <<<"${out}"
check "symlink points at the rabbit"          test "$(readlink "${T}/tmp/.nnf")" == "${rabbit}/usernetes"
check "runroot resolves onto the rabbit"      test "$(readlink -f "${T}/tmp/.nnf/run-$(id -u)/containers")" == "${rabbit}/usernetes/run-$(id -u)/containers"
rm -f "${T:?}/tmp/.nnf"; mkdir -p "${T}/tmp/.nnf"
out=$(fn USERNETES_RUNROOT_SYMLINK=1 usernetes_setup_podman_storage 2>&1); rc=$?
check "real directory at the symlink path is an error" test "${rc}" != 0
rmdir "${T:?}/tmp/.nnf"
echo "== other containers config is carried over"
mkdir -p "${T}/home/.config/containers"
echo '[containers]' > "${T}/home/.config/containers/containers.conf"
echo 'ignored' > "${T}/home/.config/containers/storage-ssd.conf"
out=$(fn usernetes_setup_podman_storage 2>&1); rc=$?
check "containers.conf copied next to storage.conf" test -f "${rabbit}/usernetes/config/containers/containers.conf"
check "storage-*.conf variants are not copied" test ! -e "${rabbit}/usernetes/config/containers/storage-ssd.conf"
check "home containers.conf untouched"        test "$(cat "${T}/home/.config/containers/containers.conf")" == "[containers]"
out=$(fn USERNETES_STORAGE_DRIVER=overlay 'usernetes_setup_podman_storage; cat "$USERNETES_STORAGE_CONF"' 2>&1)
check "driver override reaches storage.conf"  grep -q '^\[storage.options.overlay\]' <<<"${out}"

echo "== verification"
out=$(fn PODMAN_STUB_FAIL="database graph root mismatch" usernetes_setup_podman_storage 2>&1); rc=$?
check "podman failure is fatal"               test "${rc}" != 0
check "podman stderr is shown"                grep -q "| Error: database graph root mismatch" <<<"${out}"
check "exit code is shown"                    grep -q "podman info exited 125" <<<"${out}"
check "reproduce recipe is shown"             grep -q "XDG_CONFIG_HOME=${rabbit}/usernetes/config" <<<"${out}"
out=$(fn USERNETES_CONTAINER_TECH=docker 'usernetes_setup_podman_storage; echo "STORAGE=${XDG_CONFIG_HOME:-unset}"' 2>&1)
check "non-podman engine skips storage setup" grep -q "STORAGE=unset" <<<"${out}"

echo "== source_env.sh"
mkdir -p "${T}/tmp/usernetes"
out=$(fn CONTAINER_ENGINE=podman TMPDIR="${T}/tmp" 'usernetes_setup_podman_storage; usernetes_write_source_env control-plane; cat "$TMPDIR/usernetes/source_env.sh"' 2>&1)
check "exports XDG_CONFIG_HOME"               grep -q "^export XDG_CONFIG_HOME=\"${rabbit}/usernetes/config\"$" <<<"${out}"
check "unsets CONTAINERS_STORAGE_CONF"        grep -q '^unset CONTAINERS_STORAGE_CONF$' <<<"${out}"
check "exports USERNETES_STORAGE_ROOT"        grep -q '^export USERNETES_STORAGE_ROOT=' <<<"${out}"
check "exports XDG_RUNTIME_DIR"               grep -q "^export XDG_RUNTIME_DIR=\"${T}/xdg\"$" <<<"${out}"
check "exports CNI=calico"                    grep -q '^export CNI="calico"$' <<<"${out}"
check "control plane sets KUBECONFIG"         grep -q '^export KUBECONFIG=' <<<"${out}"
check "PATH is expanded at source time"       grep -q '^export PATH="${HOME}/.local/bin:${PATH}"$' <<<"${out}"
out=$(fn CONTAINER_ENGINE=podman TMPDIR="${T}/tmp" 'usernetes_setup_podman_storage; usernetes_write_source_env worker; cat "$TMPDIR/usernetes/source_env.sh"' 2>&1)
check "worker does not set KUBECONFIG"        not_grep KUBECONFIG "${T}/tmp/usernetes/source_env.sh"
rm -rf "${T:?}/tmp"

# Line number of the first match of a pattern in a file (0 if none).
line_of() { grep -n -m1 "$1" "$2" | cut -d: -f1 || echo 0; }

echo "== end to end (stubbed)"
in_sandbox "timeout 20 bash '${T}/usernetes-start-control-plane.sh'" > "${T}/control-plane.log" 2>&1
log="${T}/control-plane.log"
check "control plane: reaches idle"           grep -q "Service will now idle indefinitely" "${log}"
check "control plane: storage verified before builds" test "$(line_of 'podman graphroot' "${log}")" -lt "$(line_of 'usernetes_base' "${log}")"
check "control plane: make up-built gets QUICK=1 and CNI=calico" grep -q 'make up-built CNI=calico QUICK=1' "${log}"
check "control plane: make sees XDG_CONFIG_HOME" grep -q "make kubeadm-init .*STORAGE=${rabbit}/usernetes/config" "${log}"
check "control plane: runs from the copied checkout" grep -q "make kubeadm-init .*PWD=${T}/tmp/usernetes" "${log}"
check "control plane: join-command published"  test -f "${T}/shared/join-command"
check "control plane: VXLAN fixups applied after up" grep -q "Applying rootless-podman VXLAN fixups" "${log}"
check "control plane: fixups run inside the node" grep -q "podman-compose exec -T node bash -c" "${log}"
check "control plane: fixups after up-built"    test "$(line_of 'make up-built' "${log}")" -lt "$(line_of 'VXLAN fixups' "${log}")"
check "control plane: source_env.sh survives cleanup" test -f "${T}/tmp/usernetes/source_env.sh"
check "control plane: source_env.sh written before builds" test "$(line_of 'Writing .*source_env.sh' "${log}")" -lt "$(line_of 'usernetes_base' "${log}")"
[[ "${verbose}" == "1" ]] && sed 's/^/    /' "${log}"

in_sandbox "timeout 20 bash '${T}/usernetes-start-worker.sh'" > "${T}/worker.log" 2>&1
log="${T}/worker.log"
check "worker: reaches idle"                  grep -q "Service will now idle indefinitely" "${log}"
check "worker: checks the API server first"    grep -q "API server is reachable" "${log}"
check "worker: joins with the shared join-command" grep -q "kubeadm join stub" "${log}"
check "worker: VXLAN fixups applied"          grep -q "Applying rootless-podman VXLAN fixups" "${log}"
check "worker: make up-built gets QUICK=1 and CNI=calico" grep -q 'make up-built CNI=calico QUICK=1' "${log}"
check "worker: source_env.sh written"         test -f "${T}/tmp/usernetes/source_env.sh"
[[ "${verbose}" == "1" ]] && sed 's/^/    /' "${log}"

in_sandbox CURL_STUB_FAIL=1 "timeout 20 bash '${T}/usernetes-start-worker.sh'" > "${T}/worker-noapi.log" 2>&1; rc=$?
check "worker: unreachable API server fails before join" test "${rc}" != 0
check "worker: unreachable API server names the address" grep -q "Nothing answers on 10.0.0.5:6443" "${T}/worker-noapi.log"
check "worker: does not run kubeadm-join then"  not_grep "make kubeadm-join" "${T}/worker-noapi.log"
rm -f "${T:?}/shared/join-command"
in_sandbox "bash '${T}/usernetes-start-worker.sh'" > "${T}/worker-nojoin.log" 2>&1; rc=$?
check "worker: missing join-command fails fast" test "${rc}" != 0
check "worker: missing join-command fails before storage setup" not_grep 'Writing .*storage.conf' "${T}/worker-nojoin.log"

echo "== debug-storage.sh (stubbed)"
in_sandbox "bash '${T}/debug-storage.sh'" > "${T}/debug.log" 2>&1; rc=$?
check "debug: exits 0 with working podman"    test "${rc}" == 0
check "debug: podman reads our storage.conf"  grep -q "podman is reading our storage.conf" "${T}/debug.log"
check "debug: graphroot on the rabbit"        grep -q "graphroot is on the rabbit" "${T}/debug.log"
check "debug: volume lands on the rabbit"     grep -q "volume data is on the rabbit" "${T}/debug.log"
check "debug: import leaves layers on rabbit" grep -q "layer(s) under" "${T}/debug.log"
check "debug: build step passes"              grep -q "✅ podman build" "${T}/debug.log"
check "debug: test image and volume removed"  not_grep "u7s-debug" <<<"$(ls "${rabbit}/usernetes/config/containers/storage/volumes" 2>/dev/null)"
check "debug: no diagnostics on success"      not_grep "DIAGNOSTICS" "${T}/debug.log"
[[ "${verbose}" == "1" ]] && sed 's/^/    /' "${T}/debug.log"
in_sandbox PODMAN_STUB_FAIL="storage.conf is bad" "bash '${T}/debug-storage.sh'" > "${T}/debug-fail.log" 2>&1; rc=$?
check "debug: exits non-zero with broken podman" test "${rc}" != 0
check "debug: shows podman error"             grep -q "Error: storage.conf is bad" "${T}/debug-fail.log"
check "debug: diagnostics shown on failure"   grep -q "DIAGNOSTICS: can podman's namespace see the rabbit" "${T}/debug-fail.log"
in_sandbox "bash '${T}/debug-storage.sh' --keep" > "${T}/debug-keep.log" 2>&1; rc=$?
check "debug: --keep leaves the volume"       test -d "${rabbit}/usernetes/config/containers/storage/volumes/u7s-debug-$(grep -oP 'u7s-debug-\K[0-9]+' "${T}/debug-keep.log" | head -1)"

echo
echo "${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
