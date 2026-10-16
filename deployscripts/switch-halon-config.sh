#!/usr/bin/env bash
set -euo pipefail
ISOLATION_MODE="${ISOLATION_MODE:-subnet-nsg}"
source "$(dirname -- "$0")/loadtest-common.sh"

MODE="${1:-}"
[[ $# == 1 && "$MODE" =~ ^(normal|loadtest)$ ]] || fail "Usage: bash deployscripts/switch-halon-config.sh normal|loadtest"
CLEAR_TIMEOUT_SECONDS="${CLEAR_TIMEOUT_SECONDS:-120}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600s}"
[[ "$CLEAR_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "CLEAR_TIMEOUT_SECONDS must be positive"
OVERLAY="$REPO_ROOT/main/environments/aks-loadtest.yaml"
[[ -f "$OVERLAY" ]] || fail "Missing overlay: $OVERLAY"
printf 'WARNING: LAB USE ONLY. This will DELETE ALL queued messages without bounces, including held and deferred mail, from every smtpd pod in this release.\n'
printf 'Context: %s\nNamespace: %s\nRelease: %s\nTarget configuration: %s\n' "$TARGET_CONTEXT" "$HALON_NAMESPACE" "$HALON_RELEASE" "$MODE"
printf 'Stop any other SMTP senders before continuing. NSG rules will not be changed.\n'
printf 'Type DELETE to confirm, or anything else to cancel: '
confirmation=""
if ! IFS= read -r confirmation || [[ "$confirmation" != DELETE ]]; then
    fail "Cancelled; no queues or configuration were changed"
fi
check_cluster

halon_kube() { kubectl --context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" "$@"; }
selector="app.kubernetes.io/name=smtpd,app.kubernetes.io/instance=$HALON_RELEASE"
generator_selector="app.kubernetes.io/instance=$LOADTEST_RELEASE,app.kubernetes.io/component=generator"
releases=$(loadtest_helm list --deployed --failed --pending --uninstalling -o json)
has_harness=false
if jq -e --arg name "$LOADTEST_RELEASE" 'any(.[]; .name == $name)' <<< "$releases" >/dev/null; then
    has_harness=true
fi
if [[ "$MODE" == loadtest ]]; then
    [[ "$has_harness" == true ]] || fail "Install the idle load-test harness before switching to loadtest"
    [[ "$LOADTEST_RELEASE" == halon-loadtest && "$LOADTEST_NAMESPACE" == halon-loadtest ]] \
        || fail "The standard overlay requires release and namespace halon-loadtest"
    kube rollout status deployment/"$LOADTEST_RELEASE-sink" --timeout="$ROLLOUT_TIMEOUT"
fi
if [[ "$has_harness" == true ]]; then
    loadtest_helm upgrade "$LOADTEST_RELEASE" "$REPO_ROOT/loadtest" --reuse-values \
        --set generator.replicas=0 --wait --timeout="$ROLLOUT_TIMEOUT"
    kube wait --for=delete pods -l "$generator_selector" --timeout="$ROLLOUT_TIMEOUT"
fi

halon_kube rollout status statefulset/"$HALON_RELEASE-smtpd" --timeout="$ROLLOUT_TIMEOUT"
statefulset=$(halon_kube get statefulset "$HALON_RELEASE-smtpd" -o json)
expected=$(jq -er '.spec.replicas | select(. > 0)' <<< "$statefulset")
owner=$(jq -er '.metadata.uid' <<< "$statefulset")
pods=$(halon_kube get pods -l "$selector" -o json)
jq -e --arg uid "$owner" --argjson count "$expected" '
    (.items | length) == $count and all(.items[];
        .metadata.deletionTimestamp == null and
        any(.metadata.ownerReferences[]; .uid == $uid and .controller == true) and
        any(.status.conditions[]; .type == "Ready" and .status == "True"))' <<< "$pods" >/dev/null \
    || fail "All expected smtpd replicas must be Ready and owned by this release before clearing queues"
mapfile -t pod_names < <(jq -r '.items[].metadata.name' <<< "$pods")
states=(--state ACTIVE --state DEFER --state HOLD --state UPDATE --state SENDING --state OTHER)
queue_total() {
    local response
    response=$(halon_kube exec "$1" -c smtpd -- /opt/halon/bin/halonctl queue list --json --limit 1 "${states[@]}")
    jq -er '.paging.total | tostring | select(test("^[0-9]+$")) | tonumber' <<< "$response"
}

printf 'Clearing ALL mail from %s/%s, including held and deferred messages. Stop any other SMTP senders before continuing.\n' "$HALON_NAMESPACE" "$HALON_RELEASE"
for pod in "${pod_names[@]}"; do
    count=$(queue_total "$pod")
    printf '%s: %s queued recipients before cleanup\n' "$pod" "$count"
done
deadline=$((SECONDS + CLEAR_TIMEOUT_SECONDS))
while :; do
    remaining=0
    for pod in "${pod_names[@]}"; do
        count=$(queue_total "$pod")
        if [[ "$count" -gt 0 ]]; then
            halon_kube exec "$pod" -c smtpd -- /opt/halon/bin/halonctl queue update --delete --all-states --freeze
        fi
        count=$(queue_total "$pod")
        remaining=$((remaining + count))
    done
    [[ "$remaining" -gt 0 ]] || break
    [[ "$SECONDS" -lt "$deadline" ]] || fail "Queues did not clear; Halon configuration was not switched"
    sleep 2
done
for pod in "${pod_names[@]}"; do
    [[ "$(queue_total "$pod")" == 0 ]] || fail "New mail arrived; stop all senders before switching"
done

extra_values=""
[[ "$MODE" != loadtest ]] || extra_values="$OVERLAY"
RELEASE_NAME="$HALON_RELEASE" NAMESPACE="$HALON_NAMESPACE" \
    TARGET_CONTEXT="$TARGET_CONTEXT" RESOURCE_GROUP="$RESOURCE_GROUP" AKS_CLUSTER_NAME="$AKS_CLUSTER_NAME" \
    EXTRA_VALUES_FILES="$extra_values" INSTALL_ELASTICSEARCH=false \
    sh "$SCRIPT_DIR/install-aks.sh"
halon_kube rollout status statefulset/"$HALON_RELEASE-smtpd" --timeout="$ROLLOUT_TIMEOUT"
values=$(helm get values "$HALON_RELEASE" --all --kube-context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" -o json)
if jq -e '.global.dlpd.enabled == true' <<< "$values" >/dev/null; then
    halon_kube rollout status deployment/"$HALON_RELEASE-dlpd" --timeout="$ROLLOUT_TIMEOUT"
fi
if [[ "$MODE" == loadtest ]]; then
    check_halon_route
    jq -e '.smtpd.istio.excludeInboundPorts == "25"' <<< "$values" >/dev/null \
        || fail "Inbound SMTP exclusion missing after loadtest switch"
else
    jq -e '.smtpd.relayOverride.enabled == false and .smtpd.relayOverride.networkPolicy.enabled == false' <<< "$values" >/dev/null \
        || fail "Sink routing or test policy is still enabled"
    policies=$(halon_kube get networkpolicy -o json)
    jq -e --arg name "$HALON_RELEASE-smtpd-loadtest-egress" 'all(.items[]; .metadata.name != $name)' <<< "$policies" >/dev/null \
        || fail "Load-test egress policy was not removed"
fi
if [[ "$has_harness" == true ]]; then
    kube exec deployment/"$LOADTEST_RELEASE-sink" -- python3 -c '
import socket, sys
with socket.create_connection((sys.argv[1], 25), timeout=10) as connection:
    connection.settimeout(10)
    banner = connection.recv(512)
    if not banner.startswith(b"220 "):
        raise SystemExit("SMTP banner verification failed: " + repr(banner))
    print("SMTP banner verified: " + banner.decode().strip())
    connection.sendall(b"QUIT\r\n")
' "$HALON_RELEASE-smtpd.$HALON_NAMESPACE.svc.cluster.local" \
    || fail "Configuration was applied, but the SMTP banner check failed; keep the NSG safeguard and inspect Istio/listener configuration"
else
    printf 'No harness present: SMTP banner check skipped; verify connectivity from your test client.\n'
fi
printf 'Switched Halon to %s. Generator stopped; sink, node pool and NSG retained.\n' "$MODE"
printf 'No NSG rules were changed. Verify loaded routing and SMTP connectivity before manually removing the safeguard.\n'