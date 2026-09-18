#!/bin/sh
set -eu

# Enables the AKS Istio service mesh add-on and reports the active control plane revision.
# The resolved revision is written to stdout; all progress output goes to stderr so that
# callers can do: ISTIO_REVISION=$(sh ./deployscripts/install-istio.sh)

RESOURCE_GROUP="${RESOURCE_GROUP:-AppRelayPOC}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-AppRelayPOC-aks}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-aks-istio-system}"
ISTIO_LABEL_NAMESPACES="${ISTIO_LABEL_NAMESPACES:-}"
ISTIO_REVISION="${ISTIO_REVISION:-}"

log() {
    echo "$@" >&2
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $1"
        exit 1
    fi
}

require_cmd az
require_cmd kubectl

if ! az account show >/dev/null 2>&1; then
    log "No active Azure session detected. Starting interactive az login..."
    az login >/dev/null
fi

mesh_mode=$(az aks show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER_NAME" \
    --query "serviceMeshProfile.mode" \
    --output tsv 2>/dev/null || true)

if [ "$mesh_mode" != "Istio" ]; then
    log "Enabling Istio service mesh add-on on '$AKS_CLUSTER_NAME' (resource group '$RESOURCE_GROUP')"
    az aks mesh enable \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --output none
else
    log "Istio service mesh add-on already enabled on '$AKS_CLUSTER_NAME'"
fi

# No ingress or egress gateway is enabled here on purpose: smtpd egresses TCP 25 directly
# via the node subnet and NAT gateway, bypassing the sidecar (see smtpd istio values).

if [ -z "$ISTIO_REVISION" ]; then
    ISTIO_REVISION=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --query "serviceMeshProfile.istio.revisions[0]" \
        --output tsv 2>/dev/null || true)
fi

if [ -z "$ISTIO_REVISION" ] || [ "$ISTIO_REVISION" = "None" ]; then
    ISTIO_REVISION=$(kubectl --context "$TARGET_CONTEXT" \
        -n "$ISTIO_NAMESPACE" \
        get pods -l app=istiod \
        -o "jsonpath={.items[0].metadata.labels['istio\\.io/rev']}" 2>/dev/null || true)
fi

if [ -z "$ISTIO_REVISION" ]; then
    log "ERROR: Could not determine the Istio control plane revision. Set ISTIO_REVISION explicitly."
    exit 1
fi

log "Istio control plane revision: $ISTIO_REVISION"

for ns in $ISTIO_LABEL_NAMESPACES; do
    log "Labelling namespace '$ns' for sidecar injection (istio.io/rev=$ISTIO_REVISION)"
    kubectl --context "$TARGET_CONTEXT" label namespace "$ns" \
        "istio.io/rev=$ISTIO_REVISION" --overwrite >/dev/null
done

printf '%s\n' "$ISTIO_REVISION"
