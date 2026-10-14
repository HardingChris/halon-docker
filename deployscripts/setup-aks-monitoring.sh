#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/loadtest-common.sh"

check_cluster
MONITOR_RESOURCE_GROUP="${MONITOR_RESOURCE_GROUP:-$RESOURCE_GROUP}"
MONITOR_WORKSPACE_NAME="${MONITOR_WORKSPACE_NAME:-halon-lab-metrics}"
GRAFANA_NAME="${GRAFANA_NAME:-halon-lab-grafana}"
CREATE_MONITORING_RESOURCES="${CREATE_MONITORING_RESOURCES:-false}"
[[ "$CREATE_MONITORING_RESOURCES" =~ ^(true|false)$ ]] || fail "Use true/false for CREATE_MONITORING_RESOURCES"
location=$(jq -r '.location' <<< "$CLUSTER_JSON")
if [[ "$CREATE_MONITORING_RESOURCES" == true ]]; then
    workspaces=$(az monitor account list -g "$MONITOR_RESOURCE_GROUP" -o json)
    if ! jq -e --arg name "$MONITOR_WORKSPACE_NAME" 'any(.[]; .name == $name)' <<< "$workspaces" >/dev/null; then
        az monitor account create -g "$MONITOR_RESOURCE_GROUP" -n "$MONITOR_WORKSPACE_NAME" -l "$location" -o none
    fi
    grafanas=$(az grafana list -g "$MONITOR_RESOURCE_GROUP" -o json)
    if ! jq -e --arg name "$GRAFANA_NAME" 'any(.[]; .name == $name)' <<< "$grafanas" >/dev/null; then
        az grafana create -g "$MONITOR_RESOURCE_GROUP" -n "$GRAFANA_NAME" -l "$location" -o none
    fi
fi
workspace_id="${AZURE_MONITOR_WORKSPACE_ID:-$(az monitor account show -g "$MONITOR_RESOURCE_GROUP" -n "$MONITOR_WORKSPACE_NAME" --query id -o tsv)}"
grafana_id="${GRAFANA_RESOURCE_ID:-$(az grafana show -g "$MONITOR_RESOURCE_GROUP" -n "$GRAFANA_NAME" --query id -o tsv)}"
az aks update -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id "$workspace_id" --grafana-resource-id "$grafana_id" -o none
kubectl --context "$TARGET_CONTEXT" wait --for=condition=Established crd/podmonitors.azmonitoring.coreos.com --timeout=300s
printf 'Managed Prometheus enabled and Grafana linked. Verify scrape targets and Grafana access before testing.\n'