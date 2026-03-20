#!/bin/sh
set -eu

# Optional context argument. Falls back to TARGET_CONTEXT env var.
TARGET_CONTEXT="${1:-${TARGET_CONTEXT:-}}"

ELASTIC_HELM_REPO_NAME="${ELASTIC_HELM_REPO_NAME:-elastic}"
ELASTIC_HELM_REPO_URL="${ELASTIC_HELM_REPO_URL:-https://helm.elastic.co}"

ELASTIC_OPERATOR_RELEASE="${ELASTIC_OPERATOR_RELEASE:-elastic-operator}"
ELASTIC_OPERATOR_CHART="${ELASTIC_OPERATOR_CHART:-$ELASTIC_HELM_REPO_NAME/eck-operator}"
ELASTIC_OPERATOR_NAMESPACE="${ELASTIC_OPERATOR_NAMESPACE:-elastic-system}"
ELASTIC_OPERATOR_STATEFULSET="${ELASTIC_OPERATOR_STATEFULSET:-elastic-operator}"

ELASTIC_STACK_RELEASE="${ELASTIC_STACK_RELEASE:-es-quickstart}"
ELASTIC_STACK_CHART="${ELASTIC_STACK_CHART:-$ELASTIC_HELM_REPO_NAME/eck-stack}"
ELASTIC_STACK_NAMESPACE="${ELASTIC_STACK_NAMESPACE:-elastic-stack}"
ELASTIC_ENABLE_KIBANA="${ELASTIC_ENABLE_KIBANA:-false}"

WAIT_FOR_OPERATOR="${WAIT_FOR_OPERATOR:-true}"
OPERATOR_READY_TIMEOUT="${OPERATOR_READY_TIMEOUT:-300s}"

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

if [ -z "$TARGET_CONTEXT" ]; then
    echo "ERROR: TARGET_CONTEXT is required (as arg 1 or env var)." >&2
    exit 1
fi

require_cmd helm
require_cmd kubectl

require_kube_context "$TARGET_CONTEXT"

echo "Adding/updating Helm repo '$ELASTIC_HELM_REPO_NAME' from $ELASTIC_HELM_REPO_URL"
helm repo add "$ELASTIC_HELM_REPO_NAME" "$ELASTIC_HELM_REPO_URL" --force-update >/dev/null
helm repo update >/dev/null

echo "Installing/upgrading ECK operator: $ELASTIC_OPERATOR_CHART"
helm upgrade --install "$ELASTIC_OPERATOR_RELEASE" "$ELASTIC_OPERATOR_CHART" \
    --kube-context "$TARGET_CONTEXT" \
    --namespace "$ELASTIC_OPERATOR_NAMESPACE" \
    --create-namespace

case "$WAIT_FOR_OPERATOR" in
    true|TRUE|1|yes|YES)
        echo "Waiting for operator StatefulSet '$ELASTIC_OPERATOR_STATEFULSET' to be ready"
        kubectl --context "$TARGET_CONTEXT" \
            -n "$ELASTIC_OPERATOR_NAMESPACE" \
            rollout status "statefulset/$ELASTIC_OPERATOR_STATEFULSET" \
            --timeout "$OPERATOR_READY_TIMEOUT"
        ;;
    *)
        echo "Skipping operator readiness wait"
        ;;
esac

echo "Installing/upgrading Elastic stack: $ELASTIC_STACK_CHART"
helm upgrade --install "$ELASTIC_STACK_RELEASE" "$ELASTIC_STACK_CHART" \
    --kube-context "$TARGET_CONTEXT" \
    --namespace "$ELASTIC_STACK_NAMESPACE" \
    --create-namespace \
    --set "eck-kibana.enabled=$ELASTIC_ENABLE_KIBANA"

echo "Done. Elasticsearch stack release '$ELASTIC_STACK_RELEASE' deployed in namespace '$ELASTIC_STACK_NAMESPACE'."
