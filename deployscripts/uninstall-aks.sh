#!/bin/sh
set -eu

# Configuration
RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"
UNINSTALL_ELASTICSEARCH="${UNINSTALL_ELASTICSEARCH:-true}"
ELASTIC_OPERATOR_RELEASE="${ELASTIC_OPERATOR_RELEASE:-elastic-operator}"
ELASTIC_OPERATOR_NAMESPACE="${ELASTIC_OPERATOR_NAMESPACE:-elastic-system}"
ELASTIC_STACK_RELEASE="${ELASTIC_STACK_RELEASE:-es-quickstart}"
ELASTIC_STACK_NAMESPACE="${ELASTIC_STACK_NAMESPACE:-elastic-stack}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1" >&2
        exit 1
    fi
}

require_kube_context() {
    context_name="$1"
    if ! kubectl config get-contexts "$context_name" >/dev/null 2>&1; then
        echo "ERROR: kube context '$context_name' was not found in kubeconfig." >&2
        exit 1
    fi
}

ensure_azure_login() {
    if az account show >/dev/null 2>&1; then
        return 0
    fi

    echo "No active Azure session detected. Starting interactive az login..."
    az login >/dev/null
}

uninstall_release_if_exists() {
    release_name="$1"
    namespace="$2"

    if helm status "$release_name" --kube-context "$TARGET_CONTEXT" --namespace "$namespace" >/dev/null 2>&1; then
        echo "Uninstalling release '$release_name' from namespace '$namespace'"
        helm uninstall "$release_name" \
            --kube-context "$TARGET_CONTEXT" \
            --namespace "$namespace"
    else
        echo "Skipping release '$release_name' in namespace '$namespace' (not installed)"
    fi
}

require_cmd az
require_cmd helm
require_cmd kubectl
require_cmd kubelogin

require_kube_context "$TARGET_CONTEXT"

case "$TARGET_CONTEXT" in
    *minikube*)
        echo "ERROR: Target context '$TARGET_CONTEXT' appears to be Minikube. Use uninstall-minikube.sh for local clusters." >&2
        exit 1
        ;;
esac

ensure_azure_login

uninstall_release_if_exists "$RELEASE_NAME" "$NAMESPACE"

case "$UNINSTALL_ELASTICSEARCH" in
    true|TRUE|1|yes|YES)
        uninstall_release_if_exists "$ELASTIC_STACK_RELEASE" "$ELASTIC_STACK_NAMESPACE"
        uninstall_release_if_exists "$ELASTIC_OPERATOR_RELEASE" "$ELASTIC_OPERATOR_NAMESPACE"
        ;;
    false|FALSE|0|no|NO|"")
        echo "Skipping Elasticsearch uninstall (UNINSTALL_ELASTICSEARCH=$UNINSTALL_ELASTICSEARCH)"
        ;;
    *)
        echo "ERROR: Invalid UNINSTALL_ELASTICSEARCH value '$UNINSTALL_ELASTICSEARCH'. Use true/false." >&2
        exit 1
        ;;
esac

echo "Done. Uninstall completed for context '$TARGET_CONTEXT'."
