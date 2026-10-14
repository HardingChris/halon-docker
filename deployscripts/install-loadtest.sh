#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/loadtest-common.sh"

ACR_NAME="${ACR_NAME:-apprelaypoccontreg}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
CREATE_NODEPOOL="${CREATE_NODEPOOL:-false}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
NODE_COUNT="${NODE_COUNT:-3}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D8s_v5}"
VALUES_FILE="${VALUES_FILE:-}"

check_cluster
[[ "$CREATE_NODEPOOL" =~ ^(true|false)$ && "$BUILD_IMAGE" =~ ^(true|false)$ ]] || fail "Use true/false for CREATE_NODEPOOL and BUILD_IMAGE"
[[ "$NODEPOOL_NAME" =~ ^[a-z][a-z0-9]{0,11}$ ]] || fail "Invalid Linux node pool name"
[[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "NODE_COUNT must be positive"
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || fail "VALUES_FILE does not exist"
kubectl --context "$TARGET_CONTEXT" get crd podmonitors.azmonitoring.coreos.com >/dev/null \
    || fail "Enable Azure Managed Prometheus first"

pools=$(az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -o json)
if ! jq -e --arg name "$NODEPOOL_NAME" 'any(.[]; .name == $name)' <<< "$pools" >/dev/null; then
    [[ "$CREATE_NODEPOOL" == true ]] || fail "Node pool missing; set CREATE_NODEPOOL=true after reviewing cost and quota"
    reference=$(jq -c '[.[] | select(.mode == "System")][0]' <<< "$pools")
    subnet="${VNET_SUBNET_ID:-$(jq -r '.vnetSubnetId // empty' <<< "$reference")}"
    pod_subnet="${POD_SUBNET_ID:-$(jq -r '.podSubnetId // empty' <<< "$reference")}"
    [[ -n "$subnet" ]] || fail "Cannot discover the lab subnet; set VNET_SUBNET_ID"
    args=(--vnet-subnet-id "$subnet")
    if [[ -n "$pod_subnet" ]]; then
        args+=(--pod-subnet-id "$pod_subnet")
        allocation=$(jq -r '.podIpAllocationMode // empty' <<< "$reference")
        [[ -z "$allocation" ]] || args+=(--pod-ip-allocation-mode "$allocation")
    fi
    printf 'Creating %s: %s nodes of %s in %s\n' "$NODEPOOL_NAME" "$NODE_COUNT" "$NODE_VM_SIZE" "$subnet"
    az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" \
        --name "$NODEPOOL_NAME" --mode User --node-count "$NODE_COUNT" --node-vm-size "$NODE_VM_SIZE" \
        --node-taints dedicated=loadtest:NoSchedule --tags purpose=halon-loadtest "${args[@]}" -o none
fi
pool=$(az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -n "$NODEPOOL_NAME" -o json)
jq -e '.mode == "User" and .enableAutoScaling != true and ((.nodeTaints // []) | index("dedicated=loadtest:NoSchedule") != null)' <<< "$pool" >/dev/null \
    || fail "Load-test pool must be a tainted User pool with autoscaling disabled"
check_cluster

repository="$ACR_NAME.azurecr.io/halon/loadtest"
if [[ "$BUILD_IMAGE" == true ]]; then
    require_cmd docker
    az acr login -n "$ACR_NAME" -o none
    docker build -t "$repository:$IMAGE_TAG" "$REPO_ROOT/loadtest/images"
    docker push "$repository:$IMAGE_TAG"
fi
args=()
[[ -z "$VALUES_FILE" ]] || args+=(-f "$VALUES_FILE")
loadtest_helm upgrade --install "$LOADTEST_RELEASE" "$REPO_ROOT/loadtest" \
    --create-namespace --wait --timeout 10m "${args[@]}" \
    --set-string "image.repository=$repository" --set-string "image.tag=$IMAGE_TAG" \
    --set-string "halon.namespace=$HALON_NAMESPACE" --set-string "halon.release=$HALON_RELEASE" \
    --set-string "halon.service=$HALON_RELEASE-smtpd" \
    --set-string "nodeSelector.kubernetes\\.azure\\.com/agentpool=$NODEPOOL_NAME" \
    --set generator.replicas=0
printf 'Sink deployed. Generator is stopped. Apply the Halon overlay, then perform isolation and one-message smoke checks before running load.\n'