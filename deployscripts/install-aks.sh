#!/bin/sh
set -eu

# Configuration
RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
ACR_NAME="${ACR_NAME:-apprelaypoccontreg}"
CHART_REPOSITORY="${CHART_REPOSITORY:-helm}"
MAIN_CHART_VERSION="${MAIN_CHART_VERSION:-0.1.2}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"
INSTALL_ELASTICSEARCH="${INSTALL_ELASTICSEARCH:-true}"
ELASTIC_STACK_NAMESPACE="${ELASTIC_STACK_NAMESPACE:-elastic-stack}"
ELASTICSEARCH_USERNAME="${ELASTICSEARCH_USERNAME:-elastic}"
ELASTICSEARCH_PASSWORD="${ELASTICSEARCH_PASSWORD:-}"
ELASTICSEARCH_SECRET_NAME="${ELASTICSEARCH_SECRET_NAME:-elasticsearch-es-elastic-user}"
ELASTICSEARCH_SECRET_KEY="${ELASTICSEARCH_SECRET_KEY:-elastic}"
ELASTICSEARCH_WAIT_FOR_SECRET="${ELASTICSEARCH_WAIT_FOR_SECRET:-true}"
ELASTICSEARCH_SECRET_TIMEOUT_SECONDS="${ELASTICSEARCH_SECRET_TIMEOUT_SECONDS:-300}"
ELASTICSEARCH_SECRET_POLL_SECONDS="${ELASTICSEARCH_SECRET_POLL_SECONDS:-5}"

# Paths
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ENV_VALUES="$REPO_ROOT/main/environments/aks-test.yaml"
ELASTIC_INSTALL_SCRIPT="$SCRIPT_DIR/install-elasticsearch.sh"

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

resolve_elasticsearch_password() {
    if [ -n "$ELASTICSEARCH_PASSWORD" ]; then
        printf '%s\n' "$ELASTICSEARCH_PASSWORD"
        return 0
    fi

    secret_password=$(kubectl --context "$TARGET_CONTEXT" \
        -n "$ELASTIC_STACK_NAMESPACE" \
        get secret "$ELASTICSEARCH_SECRET_NAME" \
        -o "go-template={{index .data \"$ELASTICSEARCH_SECRET_KEY\" | base64decode}}" 2>/dev/null || true)
    if [ -n "$secret_password" ]; then
        printf '%s\n' "$secret_password"
        return 0
    fi

    case "$ELASTICSEARCH_WAIT_FOR_SECRET" in
        true|TRUE|1|yes|YES)
            ;;
        *)
            return 0
            ;;
    esac

    timeout="$ELASTICSEARCH_SECRET_TIMEOUT_SECONDS"
    poll="$ELASTICSEARCH_SECRET_POLL_SECONDS"

    case "$timeout" in
        ''|*[!0-9]*) timeout=300 ;;
    esac
    case "$poll" in
        ''|*[!0-9]*) poll=5 ;;
    esac
    if [ "$poll" -le 0 ]; then
        poll=5
    fi

    echo "Waiting for Elasticsearch secret '$ELASTICSEARCH_SECRET_NAME' in namespace '$ELASTIC_STACK_NAMESPACE' (timeout ${timeout}s)" >&2

    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        secret_password=$(kubectl --context "$TARGET_CONTEXT" \
            -n "$ELASTIC_STACK_NAMESPACE" \
            get secret "$ELASTICSEARCH_SECRET_NAME" \
            -o "go-template={{index .data \"$ELASTICSEARCH_SECRET_KEY\" | base64decode}}" 2>/dev/null || true)
        if [ -n "$secret_password" ]; then
            printf '%s\n' "$secret_password"
            return 0
        fi

        sleep "$poll"
        elapsed=$((elapsed + poll))
    done

    echo "WARNING: Timed out waiting for Elasticsearch secret '$ELASTICSEARCH_SECRET_NAME' in namespace '$ELASTIC_STACK_NAMESPACE'." >&2
    return 0
}

require_cmd az
require_cmd helm
require_cmd kubectl
require_cmd kubelogin
require_cmd mktemp
require_cmd sleep

# Input checks
if [ ! -f "$ENV_VALUES" ]; then
    echo "ERROR: Missing values file: $ENV_VALUES" >&2
    exit 1
fi

if [ ! -f "$ELASTIC_INSTALL_SCRIPT" ]; then
    echo "ERROR: Missing Elasticsearch install helper: $ELASTIC_INSTALL_SCRIPT" >&2
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

case "$INSTALL_ELASTICSEARCH" in
    true|TRUE|1|yes|YES)
        echo "INSTALL_ELASTICSEARCH enabled; installing Elasticsearch stack"
        TARGET_CONTEXT="$TARGET_CONTEXT" sh "$ELASTIC_INSTALL_SCRIPT"
        ;;
    false|FALSE|0|no|NO|"")
        ;;
    *)
        echo "ERROR: Invalid INSTALL_ELASTICSEARCH value '$INSTALL_ELASTICSEARCH'. Use true/false." >&2
        exit 1
        ;;
esac

echo "Installing chart: $CHART_REF"
ES_PASSWORD_FILE=""
cleanup() {
    if [ -n "$ES_PASSWORD_FILE" ] && [ -f "$ES_PASSWORD_FILE" ]; then
        rm -f "$ES_PASSWORD_FILE"
    fi
}
trap cleanup EXIT INT TERM

ES_PASSWORD="$(resolve_elasticsearch_password)"
if [ -n "$ES_PASSWORD" ]; then
    ES_PASSWORD_FILE="$(mktemp)"
    printf '%s' "$ES_PASSWORD" > "$ES_PASSWORD_FILE"
    echo "Applying Elasticsearch auth override from runtime secret/environment"
    helm upgrade --install "$RELEASE_NAME" "$CHART_REF" \
        --version "$MAIN_CHART_VERSION" \
        --kube-context "$TARGET_CONTEXT" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        -f "$ENV_VALUES" \
        --set-string "global.elasticsearch.auth.username=$ELASTICSEARCH_USERNAME" \
        --set-file "global.elasticsearch.auth.password=$ES_PASSWORD_FILE" \
        --render-subchart-notes
else
    echo "WARNING: Elasticsearch password not found. Set ELASTICSEARCH_PASSWORD or ensure secret '$ELASTICSEARCH_SECRET_NAME' exists in namespace '$ELASTIC_STACK_NAMESPACE'."
    helm upgrade --install "$RELEASE_NAME" "$CHART_REF" \
        --version "$MAIN_CHART_VERSION" \
        --kube-context "$TARGET_CONTEXT" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        -f "$ENV_VALUES" \
        --render-subchart-notes
fi

echo "Done. Release '$RELEASE_NAME' deployed to context '$TARGET_CONTEXT' in namespace '$NAMESPACE'."
