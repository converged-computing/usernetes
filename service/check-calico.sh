#!/bin/bash
#
# Verify that Calico is using the routable host IP of every node as its VXLAN
# tunnel endpoint, which is what cross-node pod traffic depends on in
# Usernetes. Calico only autodetects its address when calico-node starts, so
# if `make install-cni` ran before `make sync-external-ip` covered a node,
# calico-node on that node keeps the unroutable podman bridge address. Every
# pod then looks healthy while traffic between nodes silently goes nowhere.
#
# Usage, on the control plane with source_env.sh sourced:
#   service/check-calico.sh          # report
#   service/check-calico.sh --fix    # sync-external-ip, then restart calico-node where the address is wrong

set -uo pipefail

fix=0; [[ "${1:-}" == "--fix" ]] && fix=1
: "${KUBECONFIG:?KUBECONFIG is not set; source source_env.sh in the usernetes directory first}"
usernetes_dir="$(dirname "${KUBECONFIG}")"

failures=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; failures=$((failures + 1)); }

echo "=== Node addresses"
printf '  %-18s %-16s %-16s %-16s %s\n' NODE HOST_IP INTERNAL_IP CALICO_IP VXLAN_TUNNEL
wrong_nodes=()
for node in $(kubectl get nodes -o name); do
    name="${node#node/}"
    host_ip=$(kubectl get "${node}" -o jsonpath='{.metadata.labels.usernetes/host-ip}')
    internal=$(kubectl get "${node}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    calico=$(kubectl get "${node}" -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4Address}')
    tunnel=$(kubectl get "${node}" -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr}')
    printf '  %-18s %-16s %-16s %-16s %s\n' "${name}" "${host_ip:--}" "${internal:--}" "${calico:--}" "${tunnel:--}"
    if [[ -z "${host_ip}" ]]; then
        bad "${name}: no usernetes/host-ip label; the node did not register through the usernetes entrypoint"
        continue
    fi
    if [[ "${internal}" != "${host_ip}" ]]; then
        bad "${name}: InternalIP is '${internal}', expected ${host_ip}. Run 'make sync-external-ip' on the control plane."
        wrong_nodes+=("${name}")
    fi
    if [[ -z "${calico}" ]]; then
        bad "${name}: Calico has not recorded an address yet (calico-node not started on it?)"
        wrong_nodes+=("${name}")
    elif [[ "${calico%/*}" != "${host_ip}" ]]; then
        bad "${name}: Calico detected ${calico}, expected ${host_ip}. calico-node autodetected before the InternalIP was synced; it must restart."
        wrong_nodes+=("${name}")
    fi
done
[[ "${failures}" == "0" ]] && ok "every node's Calico address is its routable host IP"

echo "=== Felix configuration"
felix=$(kubectl get felixconfiguration default -o jsonpath='{.spec.vxlanPort} {.spec.featureDetectOverride} {.spec.externalNodesList}' 2>&1)
echo "  vxlanPort / featureDetectOverride / externalNodesList: ${felix}"
[[ "${felix}" == *"ChecksumOffloadBroken=true"* ]] && ok "VXLAN checksum offload disabled by Felix" || bad "Felix is not disabling VXLAN checksum offload (expected featureDetectOverride ChecksumOffloadBroken=true)"
[[ "${felix}" == *"169.254.7.115"* ]] && ok "sentinel source address allowed for inbound VXLAN" || bad "externalNodesList does not allow 169.254.7.115"

echo "=== calico-node pods"
kubectl get pods -n calico-system -l k8s-app=calico-node -o wide 2>&1 | sed 's/^/  /'

if [[ "${failures}" != "0" && "${fix}" == "1" ]]; then
    echo "=== Fixing"
    echo "  make -C ${usernetes_dir} sync-external-ip"
    make -C "${usernetes_dir}" sync-external-ip || bad "sync-external-ip failed"
    if [[ "${#wrong_nodes[@]}" -gt 0 ]]; then
        echo "  restarting calico-node so it re-detects its address"
        kubectl rollout restart daemonset/calico-node -n calico-system
        kubectl rollout status daemonset/calico-node -n calico-system --timeout=3m
        echo "  re-checking:"
        exec "${BASH_SOURCE[0]}"
    fi
fi

echo "=== Summary"
if [[ "${failures}" == "0" ]]; then
    ok "Calico addressing looks right. If cross-node traffic still fails, test it directly:"
    echo "     kubectl exec <pod on node A> -- ping -c 3 <pod IP on node B>"
    exit 0
fi
bad "${failures} problem(s) above. Rerun with --fix to sync addresses and restart calico-node."
exit 1
