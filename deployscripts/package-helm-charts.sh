#!/bin/sh
set -eu

CHART_REPOSITORY="${CHART_REPOSITORY:-helm}"
ACR_NAME="${ACR_NAME:-apprelaypoccontreg}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MAIN_CHART_DIR="$REPO_ROOT/main"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist/helm}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1" >&2
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

if [ -z "$ACR_NAME" ]; then
    printf "Enter ACR_NAME: "
    IFS= read -r ACR_NAME
fi

if [ -z "$ACR_NAME" ]; then
    echo "ERROR: ACR_NAME cannot be empty." >&2
    exit 1
fi

require_cmd az
require_cmd helm
require_cmd awk
require_cmd mkdir

ACR_LOGIN_SERVER="$ACR_NAME.azurecr.io"
CHART_REGISTRY="oci://$ACR_LOGIN_SERVER/$CHART_REPOSITORY"

ensure_azure_login

ACR_TOKEN=$(az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken)
helm registry login "$ACR_LOGIN_SERVER" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password "$ACR_TOKEN"

echo "Building dependency artifacts into main/charts"
helm dependency build "$MAIN_CHART_DIR"

mkdir -p "$OUTPUT_DIR"
main_package=$(helm package "$MAIN_CHART_DIR" --destination "$OUTPUT_DIR" | awk '/saved it to:/ {print $NF}')
if [ -z "$main_package" ] || [ ! -f "$main_package" ]; then
    echo "ERROR: Failed to package main chart." >&2
    exit 1
fi

echo "Pushing bundled chart $(basename "$main_package")"
helm push "$main_package" "$CHART_REGISTRY"

echo "Done. Bundled main chart pushed to: $CHART_REGISTRY"
