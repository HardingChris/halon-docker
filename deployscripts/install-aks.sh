#!/bin/sh
set -eu

# Configuration
RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
ACR_NAME="${ACR_NAME:-apprelaypoccontreg}"
CHART_REPOSITORY="${CHART_REPOSITORY:-helm}"
MAIN_CHART_VERSION="${MAIN_CHART_VERSION:-0.1.1}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"

# Paths
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ENV_VALUES="$REPO_ROOT/main/environments/aks-test.yaml"

# Helpers
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

require_cmd az
require_cmd helm
require_cmd kubectl
require_cmd kubelogin

# Input checks
if [ ! -f "$ENV_VALUES" ]; then
    echo "ERROR: Missing values file: $ENV_VALUES" >&2
    exit 1
fi

# Chart source
ACR_LOGIN_SERVER="$ACR_NAME.azurecr.io"
CHART_REF="oci://$ACR_LOGIN_SERVER/$CHART_REPOSITORY/main"

# Authentication
ensure_azure_login

ACR_TOKEN=$(az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken)
helm registry login "$ACR_LOGIN_SERVER" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password "$ACR_TOKEN"

# Cluster checks
require_kube_context "$TARGET_CONTEXT"

case "$TARGET_CONTEXT" in
    *minikube*)
    echo "ERROR: Target context '$TARGET_CONTEXT' appears to be Minikube. Set TARGET_CONTEXT to an AKS context." >&2
        exit 1
        ;;
esac

echo "Installing chart: $CHART_REF"
helm upgrade --install "$RELEASE_NAME" "$CHART_REF" \
    --version "$MAIN_CHART_VERSION" \
    --kube-context "$TARGET_CONTEXT" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$ENV_VALUES" \
    --render-subchart-notes

echo "Done. Release '$RELEASE_NAME' deployed to context '$TARGET_CONTEXT' in namespace '$NAMESPACE'."
