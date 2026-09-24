#!/bin/bash
#
# Show how rootless podman delivers a published UDP port into a container:
# which interface the packet arrives on and what source address it carries.
# No usernetes involved; a throwaway python container does the receiving.
#
# This is what decides whether Calico's VXLAN source-address rule can work:
#   rootlessport (podman's default port forwarder, used with slirp4netns and
#   with bridge networks) dials the container's own IP from inside its netns,
#   so packets arrive on lo with the container's own address as source.
#   pasta forwards transparently, so packets arrive on eth0 with the real
#   remote source address.
#
# On node A (listener; waits up to 60s):
#   service/probe-port-forward.sh listen            # default podman bridge network + rootlessport
#   service/probe-port-forward.sh listen --pasta    # --network pasta (needs the pasta binary)
# On node B:
#   service/probe-port-forward.sh send <node A host IP>
#
# Options: --port N (default 18472), --image IMG (default docker.io/library/python:3-alpine)

set -uo pipefail

mode="${1:-}"; shift || true
port=18472 image="docker.io/library/python:3-alpine" network=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pasta) network="pasta" ;;
        --network) network="$2"; shift ;;
        --port) port="$2"; shift ;;
        --image) image="$2"; shift ;;
        *) target="$1" ;;
    esac
    shift
done

case "${mode}" in
listen)
    if [[ "${network}" == "pasta" ]] && ! command -v pasta >/dev/null; then
        echo "pasta binary not found in PATH. podman 4.x needs it for --network pasta." >&2
        echo "A static build can be dropped into ~/.local/bin from https://passt.top/builds/latest/x86_64/" >&2
        exit 1
    fi
    echo "podman $(podman --version | awk '{print $3}'), network mode: ${network:-default bridge (rootlessport)}"
    podman image exists "${image}" || podman pull -q "${image}" || exit 1
    netflag=(); [[ -n "${network}" ]] && netflag=(--network "${network}")
    probe=$(mktemp "${TMPDIR:-/tmp}/probe-XXXXXX.py")
    cat > "${probe}" <<'EOF'
import socket, struct, sys, subprocess
IP_PKTINFO = 8  # linux; not exported by the socket module
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, IP_PKTINFO, 1)
s.bind(("", port)); s.settimeout(120)
print("container addresses:")
print(subprocess.run(["sh", "-c", "ip -4 -o addr | awk '{print \"  \"$2\" \"$4}'"], capture_output=True, text=True).stdout, end="")
print("READY: waiting up to 120s for a packet on UDP %d" % port, flush=True)
try:
    data, anc, _, src = s.recvmsg(200, 1024)
except socket.timeout:
    print("no packet within 120s"); sys.exit(1)
ifindex = None
for level, typ, cmsg in anc:
    if level == socket.IPPROTO_IP and typ == IP_PKTINFO:
        ifindex, spec_dst, addr = struct.unpack("i4s4s", cmsg[:12])
        dst = socket.inet_ntoa(addr)
print("received %r" % data.decode(errors="replace").strip())
print("  source address: %s:%d" % src)
print("  arrived on:     %s (ifindex %s), destination %s" % (socket.if_indextoname(ifindex) if ifindex else "?", ifindex, dst))
EOF
    cid=$(podman run -d --rm "${netflag[@]}" -p "${port}:${port}/udp" -v "${probe}:/probe.py:ro" "${image}" python3 -u /probe.py "${port}") || { rm -f "${probe}"; exit 1; }
    sleep 2
    echo "processes providing this container's network and port forwarding:"
    pgrep -u "$(id -u)" -af 'rootlessport|slirp4netns|pasta|netavark|aardvark' | grep -v pgrep | cut -c1-160 | sed 's/^/    /' || echo "    (none found)"
    echo "container output:"
    podman logs -f "${cid}" 2>&1 | sed 's/^/    /'
    rm -f "${probe}"
    ;;
send)
    [[ -n "${target:-}" ]] || { echo "usage: $0 send <listener host IP> [--port N]" >&2; exit 1; }
    for i in 1 2 3; do
        echo "probe ${i} from $(hostname)" > "/dev/udp/${target}/${port}" && echo "sent probe ${i} to ${target}:${port}"
        sleep 1
    done
    ;;
*)
    sed -n '2,20p' "$0"; exit 1 ;;
esac
