#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-AppRelayPOC}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-AppRelayPOC-aks}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"
LOADTEST_RELEASE="${LOADTEST_RELEASE:-halon-loadtest}"
LOADTEST_NAMESPACE="${LOADTEST_NAMESPACE:-halon-loadtest}"
HALON_RELEASE="${HALON_RELEASE:-halon}"
HALON_NAMESPACE="${HALON_NAMESPACE:-default}"
NODEPOOL_NAME="${NODEPOOL_NAME:-loadtestpool}"
ISOLATION_MODE="${ISOLATION_MODE:-networkpolicy}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
kube() { kubectl --context "$TARGET_CONTEXT" -n "$LOADTEST_NAMESPACE" "$@"; }
loadtest_helm() { helm "$@" --kube-context "$TARGET_CONTEXT" --namespace "$LOADTEST_NAMESPACE"; }

check_subnet_smtp_block() {
    local subnet_id nsg_id subnet nsg
    local -a subnets
    jq -e '.networkProfile.networkPlugin == "azure" and .networkProfile.networkPluginMode == "overlay" and
        (.agentPoolProfiles | length > 0 and all(.[]; (.vnetSubnetId // "") != ""))' <<< "$CLUSTER_JSON" >/dev/null \
        || fail "Subnet isolation requires Azure CNI Overlay and identifiable subnets for every pool"
    mapfile -t subnets < <(jq -r '[.agentPoolProfiles[].vnetSubnetId] | unique[]' <<< "$CLUSTER_JSON")
    for subnet_id in "${subnets[@]}"; do
        subnet=$(az network vnet subnet show --ids "$subnet_id" -o json)
        nsg_id=$(jq -r '.networkSecurityGroup.id // empty' <<< "$subnet")
        [[ -n "$nsg_id" ]] || fail "Node subnet has no NSG: $subnet_id"
        nsg=$(az network nsg show --ids "$nsg_id" -o json)
        jq -e 'any(.securityRules[];
            .priority == 100 and .direction == "Outbound" and .access == "Deny" and
            (.protocol == "*" or (.protocol | ascii_downcase) == "tcp") and
            .sourceAddressPrefix == "*" and .sourcePortRange == "*" and
            (.destinationAddressPrefix == "Internet" or .destinationAddressPrefix == "*") and
            (.destinationPortRange == "25" or .destinationPortRange == "*" or
             ((.destinationPortRanges // []) | index("25") != null)))' <<< "$nsg" >/dev/null \
            || fail "Node subnet needs a priority-100 outbound deny of Internet TCP25 from all sources: $subnet_id"
    done
    printf 'Verified public TCP25 block on every node subnet; pod-to-pod NetworkPolicies are not enforced in subnet-nsg mode.\n'
}

check_cluster() {
    require_cmd az
    require_cmd kubectl
    require_cmd helm
    require_cmd jq
    [[ "$LOADTEST_NAMESPACE" != "$HALON_NAMESPACE" ]] || fail "Use a separate load-test namespace"
    CLUSTER_JSON=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" -o json)
    local server
    server=$(kubectl config view --minify --context "$TARGET_CONTEXT" -o json | jq -r '.clusters[0].cluster.server')
    jq -e --arg server "$server" '[.fqdn, .privateFqdn] | any(. != null and ($server == ("https://" + .) or $server == ("https://" + . + ":443")))' <<< "$CLUSTER_JSON" >/dev/null \
        || fail "TARGET_CONTEXT does not point at the selected AKS cluster"
    case "$ISOLATION_MODE" in
        networkpolicy)
            jq -e '.networkProfile | .networkPolicy == "azure" or .networkPolicy == "calico" or .networkPolicy == "cilium" or .networkDataplane == "cilium"' <<< "$CLUSTER_JSON" >/dev/null \
                || fail "An enforced Kubernetes NetworkPolicy engine is required; do not start load"
            ;;
        subnet-nsg) check_subnet_smtp_block ;;
        *) fail "ISOLATION_MODE must be networkpolicy or subnet-nsg" ;;
    esac
}

check_halon_route() {
    local values expected_host
    expected_host="$LOADTEST_RELEASE-sink.$LOADTEST_NAMESPACE.svc.cluster.local"
    values=$(helm get values "$HALON_RELEASE" --all --kube-context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" -o json)
    jq -e --arg host "$expected_host" --arg namespace "$LOADTEST_NAMESPACE" --arg release "$LOADTEST_RELEASE" '
        .smtpd.relayOverride.enabled == true and
        .smtpd.relayOverride.host == $host and .smtpd.relayOverride.port == 25 and
        .smtpd.relayOverride.networkPolicy.enabled == true and
        .smtpd.relayOverride.networkPolicy.sinkNamespace == $namespace and
        .smtpd.relayOverride.networkPolicy.sinkRelease == $release and
        .global.dlpd.enabled == true' <<< "$values" >/dev/null \
        || fail "Deploy the matching Halon load-test overlay with DLP and isolation first"
    kubectl --context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" get networkpolicy "$HALON_RELEASE-smtpd-loadtest-egress" >/dev/null
    kubectl --context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" rollout status statefulset/"$HALON_RELEASE-smtpd" --timeout=300s
    kubectl --context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" rollout status deployment/"$HALON_RELEASE-dlpd" --timeout=300s
}