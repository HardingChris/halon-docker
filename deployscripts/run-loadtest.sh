#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/loadtest-common.sh"

[[ "${CONFIRM_LOADTEST:-false}" == true ]] || fail "Set CONFIRM_LOADTEST=true to authorize SMTP load on the lab"
[[ "${ISOLATION_VERIFIED:-false}" == true ]] || fail "Verify egress enforcement and conflicting NetworkPolicies, then set ISOLATION_VERIFIED=true"
STAGES="${STAGES:-1 4 16 64}"
STAGE_SECONDS="${STAGE_SECONDS:-300}"
GENERATOR_REPLICAS="${GENERATOR_REPLICAS:-1}"
for value in $STAGES "$STAGE_SECONDS" "$GENERATOR_REPLICAS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "Stages, duration and replicas must be positive integers"
done
check_cluster
check_halon_route
settings=$(loadtest_helm get values "$LOADTEST_RELEASE" --all -o json)
jq -e --arg namespace "$HALON_NAMESPACE" --arg release "$HALON_RELEASE" '
    .generator.replicas == 0 and .halon.namespace == $namespace and
    .halon.release == $release and .halon.service == ($release + "-smtpd")' <<< "$settings" >/dev/null \
    || fail "Generator must be stopped and target the expected Halon release"
kube rollout status deployment/"$LOADTEST_RELEASE-sink" --timeout=300s
output="${OUTPUT_DIR:-$REPO_ROOT/dist/loadtest/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$output"
printf '%s\n' "$settings" > "$output/loadtest-values.json"
printf '%s\n' "$CLUSTER_JSON" | jq '{name, kubernetesVersion, networkProfile, agentPoolProfiles}' > "$output/cluster.json"
kubectl --context "$TARGET_CONTEXT" -n "$HALON_NAMESPACE" get statefulset "$HALON_RELEASE-smtpd" -o json \
    | jq '{name: .metadata.name, replicas: .spec.replicas, template: .spec.template, volumes: .spec.volumeClaimTemplates}' > "$output/smtpd.json"
printf 'sessions\treplicas\tstart_utc\tend_utc\n' > "$output/stages.tsv"

stop_generator() {
    if ! loadtest_helm upgrade "$LOADTEST_RELEASE" "$REPO_ROOT/loadtest" --reuse-values --set generator.replicas=0 --wait --timeout 5m; then
        printf 'WARNING: Helm stop failed; falling back to kubectl scale. Check release state.\n' >&2
        kube scale deployment/"$LOADTEST_RELEASE-generator" --replicas=0
    fi
}
trap stop_generator EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for sessions in $STAGES; do
    loadtest_helm upgrade "$LOADTEST_RELEASE" "$REPO_ROOT/loadtest" --reuse-values \
        --set "generator.replicas=$GENERATOR_REPLICAS" --set "generator.sessions=$sessions" \
        --set "generator.runSeconds=$((STAGE_SECONDS + 300))" --wait --timeout 5m
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf 'Stage: %s sessions per generator, %s replicas, %ss\n' "$sessions" "$GENERATOR_REPLICAS" "$STAGE_SECONDS"
    sleep "$STAGE_SECONDS"
    ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s\t%s\t%s\t%s\n' "$sessions" "$GENERATOR_REPLICAS" "$started" "$ended" >> "$output/stages.tsv"
    kube logs -l "app.kubernetes.io/instance=$LOADTEST_RELEASE,app.kubernetes.io/component=generator" --prefix --tail=-1 > "$output/source-$sessions.log"
    kube get pods -l "app.kubernetes.io/instance=$LOADTEST_RELEASE" -o json > "$output/pods-$sessions.json"
    kube top pods --containers > "$output/resources-$sessions.txt" || printf 'WARNING: kubectl top unavailable\n' >&2
    unhealthy=$(kube get pods -l "app.kubernetes.io/instance=$LOADTEST_RELEASE" -o json | jq '[.items[].status.containerStatuses[]? | select(.restartCount > 0 or .ready != true)] | length')
    [[ "$unhealthy" == 0 ]] || fail "Harness restarted or became unready; discard this stage and inspect $output"
    stop_generator
done
trap - EXIT
printf 'Stages complete; generator stopped, sink retained for queue drain. Results: %s\n' "$output"