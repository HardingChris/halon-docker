#!/bin/sh
set -eu

# Configuration
RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
TARGET_CONTEXT="${TARGET_CONTEXT:-$MINIKUBE_PROFILE}"
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

require_cmd helm
require_cmd kubectl
require_cmd minikube

if ! minikube -p "$MINIKUBE_PROFILE" status >/dev/null 2>&1; then
    echo "ERROR: Minikube profile '$MINIKUBE_PROFILE' is not running." >&2
    exit 1
fi

echo "Refreshing kubeconfig context for Minikube profile: $MINIKUBE_PROFILE"
minikube -p "$MINIKUBE_PROFILE" update-context >/dev/null
require_kube_context "$TARGET_CONTEXT"

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
