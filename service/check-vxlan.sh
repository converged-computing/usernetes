#!/bin/bash
#
# Diagnose the Calico VXLAN path between Usernetes nodes, from inside this
# node's container. Run on each node from the usernetes directory with
# source_env.sh sourced.
#
#   service/check-vxlan.sh                       # inspect device, routes, fdb, offload, rp_filter, nat, counters
#   service/check-vxlan.sh --pod <peer pod IP>   # also send TCP probes to a pod on the other node through the
#                                                # tunnel (port 8050, the flux broker; --port to change) and show
#                                                # whether VXLAN packets went out / came back
#   service/check-vxlan.sh --listen              # wait 20s for a UDP probe on the published flannel port (8472)
#   service/check-vxlan.sh --peer <peer host IP> # send UDP probes to the other host's 8472 (run --listen there first)
#   service/check-vxlan.sh --read                # only print the allowed-hosts set and the counters left by a
#                                                # previous run, without resetting them
#   service/check-vxlan.sh --fix                 # apply the rootless-podman fixups inside the node container:
#                                                # rewrite inbound VXLAN arriving on lo to the sentinel address
#                                                # (podman's port forwarder delivers through lo, not eth0) and set
#                                                # rp_filter loose. Run on every node, then re-check.
#
# The --listen/--peer pair tests the rootless UDP port forwarding between the
# two hosts without involving Calico at all. If that fails, VXLAN cannot work.

set -uo pipefail

pod="" peer="" listen=0 read_only=0 fix=0 port=8050
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pod) pod="$2"; shift ;;
        --port) port="$2"; shift ;;
        --peer) peer="$2"; shift ;;
        --listen) listen=1 ;;
        --read) read_only=1 ;;
        --fix) fix=1 ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
    shift
done

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
usernetes_dir="${USERNETES_DIR:-$PWD}"
[[ -f "${usernetes_dir}/docker-compose.yaml" ]] || { echo "run from the usernetes directory (no docker-compose.yaml in ${usernetes_dir})" >&2; exit 1; }
compose="${COMPOSE:-$("${usernetes_dir}/Makefile.d/detect-container-engine.sh" COMPOSE)}"
port_calico="${PORT_CALICO:-4789}"
port_probe="${PORT_FLANNEL:-8472}"

section() { echo; echo "=== $1"; }
show()    { sed 's/^/    | /'; }
# podman-compose chatters on every exec; keep only the command's own output and non-zero exit codes.
in_node() { (cd "${usernetes_dir}" && ${compose} exec -T node bash -c "$1" 2>&1) | grep -vE "^(podman-compose version|\['podman'|using podman version|podman exec |exit code: 0)"; }

section "Host $(hostname)"
podman info --format json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); h=d["host"]
print("  podman: %s   slirp4netns: %s   pasta: %s" % (
  (d.get("version") or {}).get("Version") or "?",
  (h.get("slirp4netns") or {}).get("executable") or "-",
  (h.get("pasta") or {}).get("executable") or "-"))' 2>/dev/null || echo "  (podman info unavailable)"
echo "  published UDP ports on the host (rootless port forwarder):"
ss -uln 2>/dev/null | grep -E ":(${port_calico}|${port_probe}) " | show || echo "    | none for ${port_calico}/${port_probe}"

if [[ "${fix}" == "1" ]]; then
    section "Applying rootless-podman VXLAN fixups inside the node container"
    # 1. podman's rootless port forwarder connects to the container's own IP from inside the
    #    container's netns, so forwarded VXLAN datagrams arrive on lo with a local source
    #    address. Extend the entrypoint's rewrite (eth0 only) to lo, so Felix sees the sentinel.
    in_node "if nft list chain ip u7s-calico-vxlan prerouting | grep -q 'iifname \"lo\"'; then echo 'lo rewrite rule already present'; else nft add rule ip u7s-calico-vxlan prerouting iifname \"lo\" udp dport ${port_calico} ip saddr set 169.254.7.115 && echo 'added: iifname lo udp dport ${port_calico} ip saddr set 169.254.7.115'; fi" | show
    # 2. A packet on lo whose source is the sentinel fails strict reverse-path filtering (the
    #    route to 169.254.7.115 is the default route via eth0). Loose is enough; the effective
    #    value is max(all, interface), so setting all covers vxlan.calico and any future device.
    in_node "for f in all default lo eth0 vxlan.calico; do [ -e /proc/sys/net/ipv4/conf/\$f/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/\$f/rp_filter; done; for f in all default lo eth0 vxlan.calico; do printf '%s=%s ' \$f \$(cat /proc/sys/net/ipv4/conf/\$f/rp_filter 2>/dev/null); done; echo" | show
    echo "  now watching Felix's counters for 10s (flux-sample retries constantly, so accept should start growing):"
    before=$(in_node "iptables-save -c 2>/dev/null | grep -E 'dport ${port_calico}' | grep -iE 'accept|drop'" | grep -oE '\[[0-9]+:[0-9]+\]' | tr '\n' ' ')
    sleep 10
    after=$(in_node "iptables-save -c 2>/dev/null | grep -E 'dport ${port_calico}' | grep -iE 'accept|drop'" | grep -oE '\[[0-9]+:[0-9]+\]' | tr '\n' ' ')
    echo "  [accept][drop] before: ${before}"
    echo "  [accept][drop] after:  ${after}"
    in_node "iptables-save -c 2>/dev/null | grep -E 'dport ${port_calico}' | grep -iE 'accept|drop'" | show
    exit 0
fi

if [[ "${read_only}" == "1" ]]; then
    section "Felix's allowed VXLAN source hosts"
    in_node "for s in \$(ipset list -n 2>/dev/null | grep -E 'all-vxlan-net|all-hosts'); do echo \"[\$s]\"; ipset list \$s | sed -n '/^Members:/,\$p'; done" | show
    section "Felix VXLAN accept/drop counters"
    in_node "iptables-save -c 2>/dev/null | grep -E 'dport 4789' | grep -E 'accept|drop|ACCEPT|DROP' || nft list chain ip filter cali-INPUT 2>/dev/null | grep 4789" | show
    section "VXLAN packet counters left by the previous run (not reset)"
    in_node "nft list table ip u7s-diag 2>&1" | grep -oE 'counter packets [0-9]+ bytes [0-9]+ comment "[^"]+"|No such file' | sed -E 's/counter packets ([0-9]+) bytes [0-9]+ comment "([^"]+)"/\2: \1/' | show
    exit 0
fi

section "VXLAN device inside the node container"
in_node "ip -d link show vxlan.calico" | show
in_node "ip -4 -o addr show dev eth0; ip -4 -o addr show dev vxlan.calico" | show

section "Routes to other nodes through the tunnel"
in_node "ip route show dev vxlan.calico" | show
echo "  fdb (peer MAC -> peer host IP):"
in_node "bridge fdb show dev vxlan.calico" | show
echo "  neighbours:"
in_node "ip neigh show dev vxlan.calico" | show

section "Checksum offload and rp_filter"
in_node "ethtool -k vxlan.calico | grep -E 'tx-checksum-ip-generic|tx-udp'" | show
in_node "for f in all default eth0 vxlan.calico; do printf '%s=%s ' \$f \$(cat /proc/sys/net/ipv4/conf/\$f/rp_filter 2>/dev/null); done; echo" | show

section "Stateless NAT for VXLAN (u7s-entrypoint.sh)"
in_node "nft list table ip u7s-calico-vxlan" | show

section "Felix VXLAN accept/drop rules (packet counters)"
in_node "iptables-save -c 2>/dev/null | grep -iE 'vxlan|dport ${port_calico}' || nft list ruleset 2>/dev/null | grep -iE -B1 'vxlan|dport ${port_calico}'" | show

section "Felix's allowed VXLAN source hosts"
echo "  ipsets present:"
in_node "ipset list -n 2>&1" | show
echo "  members of the VXLAN allowed-source set (169.254.7.115 and both host IPs should be here):"
in_node "found=0; for s in \$(ipset list -n 2>/dev/null | grep -E 'all-vxlan-net|all-hosts'); do found=1; echo \"[\$s]\"; ipset list \$s | sed -n '/^Members:/,\$p'; done; [ \$found = 1 ] || echo 'no all-vxlan-net / all-hosts ipset found'" | show
echo "  nft sets, in case Felix uses the nftables dataplane instead of ipset:"
in_node "nft list sets 2>/dev/null | grep -iE -A6 'hosts' || echo 'none'" | show

# Packet counters on the container's eth0 for VXLAN traffic, in a private table.
section "VXLAN packet counters on eth0 (fresh)"
# 'in' chains run before (priority -350) and after (-250) the entrypoint's raw-priority (-300)
# source rewrite, so the per-source counters show what arrives and what the rewrite made of it.
in_node "nft delete table ip u7s-diag 2>/dev/null; nft -f - <<'EOF'
table ip u7s-diag {
  chain out {
    type filter hook postrouting priority 200; policy accept;
    oifname \"eth0\" udp dport ${port_calico} counter comment \"out-total\"
  }
  chain in_before {
    type filter hook prerouting priority -350; policy accept;
    udp dport ${port_calico} counter comment \"in-total-any-iface\"
    iifname \"eth0\" udp dport ${port_calico} counter comment \"in-iif-eth0\"
    iifname \"lo\" udp dport ${port_calico} counter comment \"in-iif-lo\"
    udp dport ${port_calico} fib saddr type local counter comment \"in-before-src-is-local-ip\"
    udp dport ${port_calico} ip saddr 192.168.0.0/16 counter comment \"in-before-src-host-net\"
    udp dport ${port_calico} ip saddr 10.100.0.0/16 counter comment \"in-before-src-bridge\"
  }
  chain in_after {
    type filter hook prerouting priority -250; policy accept;
    udp dport ${port_calico} ip saddr 169.254.7.115 counter comment \"in-after-sentinel\"
    udp dport ${port_calico} ip saddr != 169.254.7.115 counter comment \"in-after-NOT-rewritten\"
  }
}
EOF
echo nft-exit=\$?"
counters() { in_node "nft list table ip u7s-diag" | grep -oE 'counter packets [0-9]+ bytes [0-9]+ comment "[^"]+"' | sed -E 's/counter packets ([0-9]+) bytes [0-9]+ comment "([^"]+)"/\2: \1/'; }
echo "  collecting for 10s (the flux worker retries its lead constantly, so traffic is flowing):"
sleep 10
counters | show

if [[ -n "${pod}" ]]; then
    section "TCP probes to ${pod}:${port} from this node through the tunnel"
    in_node "ip route get ${pod}" | show
    for i in 1 2 3; do
        in_node "timeout 2 bash -c '</dev/tcp/${pod}/${port}' 2>/dev/null && echo 'probe ${i}: connected' || echo 'probe ${i}: no answer'" | show
    done
    echo "  counters after the probes (out-total should have grown; in-* grow only if the peer answered):"
    counters | show
fi

if [[ "${listen}" == "1" ]]; then
    section "Listening 20s inside the node container on UDP ${port_probe} (run --peer <this host IP> on the other node now)"
    in_node "timeout 20 socat -u UDP-RECV:${port_probe} STDOUT" | show
    echo "  (a line 'probe from <host>' above means host-to-container UDP forwarding works)"
fi

if [[ -n "${peer}" ]]; then
    section "Sending 3 UDP probes from the node container to ${peer}:${port_probe}"
    for i in 1 2 3; do in_node "echo 'probe from $(hostname) #${i}' | socat -u STDIN UDP-SENDTO:${peer}:${port_probe}"; sleep 1; done
    echo "  sent; check the --listen output on the other node"
fi

section "Reading the results"
cat <<EOF
  - No route/fdb entries: Felix has not programmed the peer. Check calico-node logs on this node.
  - Probe from --pod: 'out-total' grows but the peer's 'vxlan in' does not: packets are lost between the hosts
    (rootless UDP forwarding, host firewall, or the source rewrite). The --listen/--peer probe isolates that.
  - 'in-iif-lo' grows while 'in-iif-eth0' stays 0: podman's port forwarder delivers through lo, the
    entrypoint's eth0-only rewrite never fires, and Felix drops the packets as coming from a non-allowed
    host. Run with --fix on every node.
  - 'in-after-sentinel' grows and Felix still drops: the sentinel is missing from cali40all-vxlan-net.
  - tx-checksum-ip-generic must be off on vxlan.calico when the rootless network is slirp4netns.
EOF
