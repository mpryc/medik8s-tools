#!/bin/bash
# Medik8s failure simulation for development
# Simulates node failures to trigger remediation flows.
#
# Usage: ./simulate-failure.sh <scenario> [options]
#
# Scenarios:
#   kubelet-stop     Stop kubelet on a worker node (triggers NHC → SNR)
#   network-partition Block API server access from a worker (tests SNR peer health)
#   storm            Stop kubelet on 2 workers simultaneously (tests NHC storm recovery)
#   recover          Restart kubelet and restore network on all workers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
SCENARIO="${1:-}"

if [ -z "$SCENARIO" ]; then
    echo "Usage: $0 <scenario>"
    echo ""
    echo "Scenarios:"
    echo "  kubelet-stop       Stop kubelet on a worker (triggers remediation)"
    echo "  network-partition  Block API server from a worker (tests peer health)"
    echo "  storm              Stop kubelet on 2 workers (tests storm protection)"
    echo "  recover            Recover all workers"
    exit 1
fi

get_worker_nodes() {
    # Try kind first; if it can't see the cluster (e.g. created with sudo),
    # fall back to kubectl node names (which match Kind container names).
    local nodes
    nodes=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep worker | sort)
    if [ -z "$nodes" ]; then
        nodes=$(${KUBECTL} get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sort)
    fi
    echo "$nodes"
}

WORKERS=()
while IFS= read -r line; do
    [ -n "$line" ] && WORKERS+=("$line")
done <<< "$(get_worker_nodes)"
if [ ${#WORKERS[@]} -lt 2 ]; then
    echo "Error: need at least 2 worker nodes. Found: ${#WORKERS[@]}"
    exit 1
fi

# Detect external cluster: if we can't access the first worker as a container,
# this is an external cluster (OCP, etc.) — print commands instead of executing.
EXTERNAL_CLUSTER=false
if ! ${CONTAINER_TOOL} container inspect "${WORKERS[0]}" &>/dev/null; then
    EXTERNAL_CLUSTER=true
fi

# For external clusters, print commands by default. Set DEV_FORCE_SIMULATE=true
# to execute them automatically via oc debug.
if [ "${EXTERNAL_CLUSTER}" = true ]; then
    # Check for oc (needed for oc debug on external clusters)
    OC_CMD=""
    if command -v oc &>/dev/null; then
        OC_CMD="oc"
    fi

    case "$SCENARIO" in
        kubelet-stop)
            TARGET="${WORKERS[0]}"
            if [ "${DEV_FORCE_SIMULATE:-false}" = true ] && [ -n "${OC_CMD}" ]; then
                echo "=== Stopping kubelet on ${TARGET} via oc debug ==="
                ${OC_CMD} debug "node/${TARGET}" -- chroot /host systemctl stop kubelet
                echo ""
                echo "Kubelet stopped on ${TARGET}. Node should go NotReady within ~40s."
            else
                echo "=== External cluster detected ==="
                echo ""
                echo "To stop kubelet on a worker, run one of:"
                echo ""
                if [ -n "${OC_CMD}" ]; then
                    echo "  oc debug node/${TARGET} -- chroot /host systemctl stop kubelet"
                fi
                echo "  ssh ${TARGET} \"sudo systemctl stop kubelet\""
                echo ""
                echo "Or to let this script do it automatically:"
                echo "  DEV_FORCE_SIMULATE=true make dev-simulate-failure"
            fi
            echo ""
            echo "Monitor with:"
            echo "  ${KUBECTL} get nodes -w"
            echo "  ${KUBECTL} get nodehealthcheck -o yaml"
            ${KUBECTL} get crd selfnoderemediations.self-node-remediation.medik8s.io &>/dev/null && \
                echo "  ${KUBECTL} get selfnoderemediation -A -w"
            ${KUBECTL} get crd fenceagentsremediations.fence-agents-remediation.medik8s.io &>/dev/null && \
                echo "  ${KUBECTL} get fenceagentsremediation -A -w"
            ${KUBECTL} get crd machinedeletionremediations.machine-deletion-remediation.medik8s.io &>/dev/null && \
                echo "  ${KUBECTL} get machinedeletionremediation -A -w"
            echo ""
            echo "On OpenShift, SNR will automatically reboot the node — no manual recovery needed."
            ;;

        network-partition)
            TARGET="${WORKERS[0]}"
            echo "=== External cluster detected ==="
            echo ""
            echo "To block API server access from a worker, run:"
            echo "  ssh ${TARGET} \"sudo iptables -A OUTPUT -p tcp --dport 6443 -j DROP\""
            echo ""
            echo "To restore:"
            echo "  ssh ${TARGET} \"sudo iptables -D OUTPUT -p tcp --dport 6443 -j DROP\""
            ;;

        storm)
            echo "=== External cluster detected ==="
            echo ""
            echo "To simulate a storm (stop kubelet on 2 workers), run:"
            echo ""
            if [ -n "${OC_CMD}" ]; then
                echo "  oc debug node/${WORKERS[0]} -- chroot /host systemctl stop kubelet &"
                echo "  oc debug node/${WORKERS[1]} -- chroot /host systemctl stop kubelet &"
                echo "  wait"
            else
                echo "  ssh ${WORKERS[0]} \"sudo systemctl stop kubelet\" &"
                echo "  ssh ${WORKERS[1]} \"sudo systemctl stop kubelet\" &"
                echo "  wait"
            fi
            echo ""
            echo "Or to let this script do it automatically:"
            echo "  DEV_FORCE_SIMULATE=true make dev-simulate-storm"
            ;;

        recover)
            echo "=== External cluster: recovery instructions ==="
            echo ""
            echo "On OpenShift with SNR, the node should reboot and recover automatically."
            echo ""
            echo "To manually restart kubelet on all workers:"
            for node in "${WORKERS[@]}"; do
                if [ -n "${OC_CMD}" ]; then
                    echo "  oc debug node/${node} -- chroot /host systemctl start kubelet"
                else
                    echo "  ssh ${node} \"sudo systemctl start kubelet\""
                fi
            done
            echo ""
            echo "Then wait for nodes:"
            echo "  ${KUBECTL} wait --for=condition=Ready node --all --timeout=120s"
            ;;

        *)
            echo "Unknown scenario: ${SCENARIO}"
            echo "Run '$0' without arguments for usage."
            exit 1
            ;;
    esac
    exit 0
fi

# --- Kind cluster path (direct container access) ---

# Verify we can access the containers. If the cluster was created with sudo,
# the containers are owned by root and we need to run this script with sudo too.
if ! ${CONTAINER_TOOL} container inspect "${WORKERS[0]}" &>/dev/null; then
    echo ""
    echo "Error: cannot access container '${WORKERS[0]}'."
    echo "The cluster was likely created with 'sudo kind create cluster'."
    echo ""
    echo "Run this script with sudo:"
    echo "  sudo $0 $SCENARIO"
    echo ""
    echo "Or via make:"
    echo "  sudo make dev-simulate-failure"
    exit 1
fi

# If running as root (sudo), prefix hints with sudo so users know to do the same
SUDO_HINT=""
if [ "$(id -u)" = "0" ]; then
    SUDO_HINT="sudo "
fi

case "$SCENARIO" in
    kubelet-stop)
        TARGET="${WORKERS[0]}"
        echo "=== Stopping kubelet on ${TARGET} ==="
        echo "This will make the node NotReady after ~40s."
        echo "NHC will detect it after the configured unhealthyCondition duration."
        ${CONTAINER_TOOL} exec "${TARGET}" systemctl stop kubelet
        echo ""
        echo "Monitor with:"
        echo "  ${KUBECTL} get nodes -w"
        echo "  ${KUBECTL} get nodehealthcheck -o yaml"
        # Show monitor hints for whichever remediator CRDs are installed
        ${KUBECTL} get crd selfnoderemediations.self-node-remediation.medik8s.io &>/dev/null && \
            echo "  ${KUBECTL} get selfnoderemediation -A -w"
        ${KUBECTL} get crd fenceagentsremediations.fence-agents-remediation.medik8s.io &>/dev/null && \
            echo "  ${KUBECTL} get fenceagentsremediation -A -w"
        ${KUBECTL} get crd machinedeletionremediations.machine-deletion-remediation.medik8s.io &>/dev/null && \
            echo "  ${KUBECTL} get machinedeletionremediation -A -w"
        echo ""
        echo "To recover: ${SUDO_HINT}$0 recover"
        ;;

    network-partition)
        TARGET="${WORKERS[0]}"
        echo "=== Blocking API server access from ${TARGET} ==="
        echo "This tests SNR's peer health decision engine."
        # Block port 6443 (API server)
        ${CONTAINER_TOOL} exec "${TARGET}" iptables -A OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || {
            echo "Error: iptables failed. The Kind node may not have iptables."
            exit 1
        }
        echo ""
        echo "SNR agent on ${TARGET} will:"
        echo "  1. Fail API server health checks"
        echo "  2. Query peers via gRPC"
        echo "  3. Decide whether to self-remediate"
        echo ""
        echo "Monitor with:"
        echo "  ${KUBECTL} get nodes -w"
        echo "  ${KUBECTL} logs -n medik8s-system -l app.kubernetes.io/component=agent --field-selector spec.nodeName=${TARGET} -f"
        echo ""
        echo "To recover: ${SUDO_HINT}$0 recover"
        ;;

    storm)
        echo "=== Simulating storm: stopping kubelet on ${WORKERS[0]} and ${WORKERS[1]} ==="
        echo "With 3 workers and minHealthy=51%, NHC should NOT remediate (only 33% healthy)."
        ${CONTAINER_TOOL} exec "${WORKERS[0]}" systemctl stop kubelet &
        ${CONTAINER_TOOL} exec "${WORKERS[1]}" systemctl stop kubelet &
        wait
        echo ""
        echo "Expected behavior:"
        echo "  - Both nodes go NotReady"
        echo "  - NHC detects storm (healthy < minHealthy threshold)"
        echo "  - NO remediation CRs created"
        echo ""
        echo "Monitor with:"
        echo "  ${KUBECTL} get nodes -w"
        echo "  ${KUBECTL} get nodehealthcheck -o jsonpath='{.items[0].status}' | python3 -m json.tool"
        echo ""
        echo "To recover one node and trigger remediation of the other:"
        echo "  ${SUDO_HINT}${CONTAINER_TOOL} exec ${WORKERS[0]} systemctl start kubelet"
        echo ""
        echo "To recover all: ${SUDO_HINT}$0 recover"
        ;;

    recover)
        echo "=== Recovering all workers ==="
        for node in "${WORKERS[@]}"; do
            echo "  Recovering ${node}..."
            # Restore kubelet
            ${CONTAINER_TOOL} exec "${node}" systemctl start kubelet 2>/dev/null || true
            # Remove iptables rules
            ${CONTAINER_TOOL} exec "${node}" iptables -D OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || true
        done
        echo ""
        echo "Waiting for nodes to become Ready..."
        ${KUBECTL} wait --for=condition=Ready node --all --timeout=120s 2>/dev/null || {
            echo "Some nodes may take longer to recover. Check with: kubectl get nodes"
        }
        echo ""
        echo "Waiting for remediation controllers to finish cleanup..."
        # Controllers need to observe the node is healthy, remove taints,
        # and strip finalizers before CRs can be deleted. Give them time.
        WAITED=0
        while [ $WAITED -lt 120 ]; do
            REMAINING=0
            ${KUBECTL} get crd selfnoderemediations.self-node-remediation.medik8s.io &>/dev/null && \
                REMAINING=$((REMAINING + $(${KUBECTL} get selfnoderemediation -A --no-headers 2>/dev/null | wc -l)))
            ${KUBECTL} get crd fenceagentsremediations.fence-agents-remediation.medik8s.io &>/dev/null && \
                REMAINING=$((REMAINING + $(${KUBECTL} get fenceagentsremediation -A --no-headers 2>/dev/null | wc -l)))
            ${KUBECTL} get crd machinedeletionremediations.machine-deletion-remediation.medik8s.io &>/dev/null && \
                REMAINING=$((REMAINING + $(${KUBECTL} get machinedeletionremediation -A --no-headers 2>/dev/null | wc -l)))
            if [ "$REMAINING" -eq 0 ]; then
                break
            fi
            echo "  $REMAINING remediation CR(s) still being processed..."
            sleep 5
            WAITED=$((WAITED + 5))
        done
        if [ "$REMAINING" -gt 0 ]; then
            echo "  Warning: $REMAINING remediation CR(s) still have finalizers after 120s."
            echo "  You may need to wait longer or check controller logs."
        fi
        echo "Done."
        ;;

    *)
        echo "Unknown scenario: ${SCENARIO}"
        echo "Run '$0' without arguments for usage."
        exit 1
        ;;
esac
