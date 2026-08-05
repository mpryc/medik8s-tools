#!/bin/bash
# Shared helpers for medik8s dev scripts.
# Source this from other scripts: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Detect kubectl or oc
detect_kubectl() {
    if command -v kubectl &>/dev/null; then
        echo kubectl
    elif command -v oc &>/dev/null; then
        echo oc
    else
        echo "Error: kubectl or oc is required but neither is installed." >&2
        echo "Install kubectl from: https://kubernetes.io/docs/tasks/tools/" >&2
        exit 1
    fi
}

# Detect container tool (podman preferred, docker fallback)
detect_container_tool() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        echo "Error: docker or podman is required but neither is installed." >&2
        exit 1
    fi
}

KUBECTL="${KUBECTL:-$(detect_kubectl)}"
CONTAINER_TOOL="${CONTAINER_TOOL:-$(detect_container_tool)}"
