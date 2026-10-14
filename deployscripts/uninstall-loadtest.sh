#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/loadtest-common.sh"

[[ "${CONFIRM_QUEUES_DRAINED:-false}" == true ]] || fail "Stop generators, drain/delete test mail including hold/deferred queues, then set CONFIRM_QUEUES_DRAINED=true"
check_cluster
DELETE_NODEPOOL="${DELETE_NODEPOOL:-false}"
[[ "$DELETE_NODEPOOL" =~ ^(true|false)$ ]] || fail "Use true/false for DELETE_NODEPOOL"
if [[ "$DELETE_NODEPOOL" == true ]]; then
    pool=$(az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -n "$NODEPOOL_NAME" -o json)
    jq -e '.mode == "User" and .tags.purpose == "halon-loadtest"' <<< "$pool" >/dev/null \
        || fail "Refusing to delete a pool not tagged purpose=halon-loadtest"
fi
loadtest_helm uninstall "$LOADTEST_RELEASE" --wait --timeout 5m
if [[ "$DELETE_NODEPOOL" == true ]]; then
    az aks nodepool delete -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -n "$NODEPOOL_NAME" --yes -o none
fi
printf 'Load-test release removed. Namespace and monitoring resources retained.\n'
printf 'Halon was not changed. After confirming all test queues are empty, rerun install-aks.sh without EXTRA_VALUES_FILES to restore normal routing.\n'