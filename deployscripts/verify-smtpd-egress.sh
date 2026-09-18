#!/bin/sh
set -eu

# Verifies that outbound TCP 25 from the smtpd pods bypasses the Istio sidecar (and therefore
# egresses straight via the node subnet / NAT gateway) while all other outbound traffic is
# captured by the sidecar and forwarded through Envoy's PassthroughCluster.
#
# Checks performed:
#   1. The istio-init exclusion is present in the pod spec (and optionally in the iptables rules).
#   2. Envoy's PassthroughCluster connection counter moves for a captured port but not for 25.
#   3. Optionally enables Istio access logging for smtpd so individual connections can be seen.

RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
TARGET_CONTEXT="${TARGET_CONTEXT:-AppRelayPOC-aks}"
POD_NAME="${POD_NAME:-}"
APP_CONTAINER="${APP_CONTAINER:-smtpd}"
PROXY_CONTAINER="${PROXY_CONTAINER:-istio-proxy}"
EXCLUDED_PORT="${EXCLUDED_PORT:-25}"
CAPTURED_PORT="${CAPTURED_PORT:-443}"
# Each probe host must actually listen on its port, otherwise the upstream connection times out
# and the access log shows UF,URX even though capture worked correctly.
TEST_HOST="${TEST_HOST:-smtp.gmail.com}"
CAPTURED_HOST="${CAPTURED_HOST:-www.google.com}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
STATS_SETTLE_SECONDS="${STATS_SETTLE_SECONDS:-20}"
STATS_POLL_SECONDS="${STATS_POLL_SECONDS:-2}"
PROBE_IMAGE="${PROBE_IMAGE:-nicolaka/netshoot}"
CHECK_IPTABLES="${CHECK_IPTABLES:-false}"
ENABLE_ACCESS_LOGS="${ENABLE_ACCESS_LOGS:-false}"
TELEMETRY_SETTLE_SECONDS="${TELEMETRY_SETTLE_SECONDS:-10}"
ACCESS_LOG_LINES="${ACCESS_LOG_LINES:-20}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1" >&2
        exit 1
    fi
}

require_cmd kubectl

kube() {
    kubectl --context "$TARGET_CONTEXT" -n "$NAMESPACE" "$@"
}

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "PASS: $*"
}

# Pod discovery
if [ -z "$POD_NAME" ]; then
    POD_NAME=$(kube get pods \
        -l "app.kubernetes.io/name=smtpd,app.kubernetes.io/instance=$RELEASE_NAME" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [ -z "$POD_NAME" ]; then
    echo "ERROR: Could not find an smtpd pod for release '$RELEASE_NAME' in namespace '$NAMESPACE'." >&2
    exit 1
fi

echo "Context:   $TARGET_CONTEXT"
echo "Namespace: $NAMESPACE"
echo "Pod:       $POD_NAME"
echo

if ! kube get pod "$POD_NAME" \
    -o jsonpath='{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}' | grep -qw "$PROXY_CONTAINER"; then
    echo "ERROR: Pod '$POD_NAME' has no '$PROXY_CONTAINER' container; the Istio sidecar is not injected." >&2
    echo "       Check that smtpd.istio.enabled is true and smtpd.istio.revision matches the cluster." >&2
    exit 1
fi

echo "=== 1. Sidecar traffic-capture exclusions ==="

INIT_ARGS=$(kube get pod "$POD_NAME" \
    -o jsonpath='{.spec.initContainers[?(@.name=="istio-init")].args}' 2>/dev/null || true)

if [ -z "$INIT_ARGS" ]; then
    # Native sidecars run istio-init as a restartable init container; fall back to the annotation.
    INIT_ARGS=$(kube get pod "$POD_NAME" \
        -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/status}' 2>/dev/null || true)
fi

EXCLUDED_ANNOTATION=$(kube get pod "$POD_NAME" \
    -o jsonpath='{.metadata.annotations.traffic\.sidecar\.istio\.io/excludeOutboundPorts}' 2>/dev/null || true)

echo "istio-init args: ${INIT_ARGS:-<none>}"
echo "excludeOutboundPorts annotation: ${EXCLUDED_ANNOTATION:-<none>}"

if echo ",$EXCLUDED_ANNOTATION," | grep -q ",$EXCLUDED_PORT,"; then
    pass "port $EXCLUDED_PORT is excluded from outbound sidecar capture"
else
    fail "port $EXCLUDED_PORT is NOT excluded from outbound sidecar capture"
fi

case "$CHECK_IPTABLES" in
    true|TRUE|1|yes|YES)
        echo
        echo "--- iptables nat rules in the pod network namespace ---"
        if ! kube debug -q -i "pod/$POD_NAME" \
            --image="$PROBE_IMAGE" \
            --target="$APP_CONTAINER" \
            --profile=netadmin \
            -- sh -c 'iptables-save -t nat 2>/dev/null | grep -E "ISTIO_OUTPUT|ISTIO_REDIRECT"'; then
            echo "WARNING: Could not read iptables rules (requires kubectl >= 1.30 and ephemeral containers)."
        fi
        ;;
esac

echo
echo "=== 2. Envoy PassthroughCluster counters ==="

# Istio's default stats config does not emit the raw cluster.PassthroughCluster.* Envoy counters,
# so use the telemetry metric, which tags passthrough traffic as destination_service_name.PassthroughCluster.
passthrough_connections() {
    kube exec "$POD_NAME" -c "$PROXY_CONTAINER" -- \
        pilot-agent request GET stats 2>/dev/null \
        | tr -d '\r' \
        | grep 'istio_tcp_connections_opened_total' \
        | grep 'PassthroughCluster' \
        | awk -F': ' '{ total += $NF } END { print total + 0 }'
}

# Probe from inside the pod network namespace. Traffic from the app container is subject to the
# sidecar's iptables rules; an ephemeral debug container in the same namespace behaves the same.
PROBE_MODE=exec
if ! kube exec "$POD_NAME" -c "$APP_CONTAINER" -- sh -c 'command -v nc' >/dev/null 2>&1; then
    PROBE_MODE=debug
fi
echo "Probe mode: $PROBE_MODE"

probe() {
    probe_host="$1"
    probe_port="$2"
    if [ "$PROBE_MODE" = exec ]; then
        probe_output=$(kube exec "$POD_NAME" -c "$APP_CONTAINER" -- \
            sh -c "nc -z -w $PROBE_TIMEOUT $probe_host $probe_port" 2>&1 || true)
    else
        probe_output=$(kube debug -q -i "pod/$POD_NAME" \
            --image="$PROBE_IMAGE" \
            --target="$APP_CONTAINER" \
            --profile=general \
            -- sh -c "nc -z -w $PROBE_TIMEOUT $probe_host $probe_port" 2>&1 || true)
    fi
    printf '%s\n' "$probe_output" | grep -v 'falling back to streaming logs' | sed 's/^/    /'
}

BEFORE=$(passthrough_connections)
BEFORE="${BEFORE:-0}"
echo "PassthroughCluster connections opened (start): $BEFORE"

# The Istio TCP stats filter reports on connection close and flushes on its own cadence,
# so the counter has to be polled rather than sampled immediately after the probe.
wait_for_increase() {
    baseline="$1"
    elapsed=0
    while [ "$elapsed" -lt "$STATS_SETTLE_SECONDS" ]; do
        current=$(passthrough_connections)
        current="${current:-0}"
        if [ "$current" -gt "$baseline" ]; then
            printf '%s\n' "$current"
            return 0
        fi
        sleep "$STATS_POLL_SECONDS"
        elapsed=$((elapsed + STATS_POLL_SECONDS))
    done
    printf '%s\n' "${current:-$baseline}"
}

echo "Probing $TEST_HOST:$EXCLUDED_PORT (expected to bypass the sidecar)"
probe "$TEST_HOST" "$EXCLUDED_PORT"
# Wait the full window so a late flush cannot be mistaken for a clean bypass.
sleep "$STATS_SETTLE_SECONDS"
AFTER_EXCLUDED=$(passthrough_connections)
AFTER_EXCLUDED="${AFTER_EXCLUDED:-0}"
echo "PassthroughCluster connections opened (after port $EXCLUDED_PORT): $AFTER_EXCLUDED"

echo "Probing $CAPTURED_HOST:$CAPTURED_PORT (expected to be captured by the sidecar)"
probe "$CAPTURED_HOST" "$CAPTURED_PORT"
AFTER_CAPTURED=$(wait_for_increase "$AFTER_EXCLUDED")
echo "PassthroughCluster connections opened (after port $CAPTURED_PORT): $AFTER_CAPTURED"

if [ "$AFTER_EXCLUDED" -eq "$BEFORE" ]; then
    pass "port $EXCLUDED_PORT did not pass through Envoy (direct egress via the node subnet / NAT gateway)"
else
    fail "port $EXCLUDED_PORT incremented the PassthroughCluster counter; it is being captured by the sidecar"
fi

if [ "$AFTER_CAPTURED" -gt "$AFTER_EXCLUDED" ]; then
    pass "port $CAPTURED_PORT was routed through the Envoy PassthroughCluster"
else
    fail "port $CAPTURED_PORT did not increment the PassthroughCluster counter (probe may not have connected)"
fi

echo
echo "=== 3. Access logs ==="

case "$ENABLE_ACCESS_LOGS" in
    true|TRUE|1|yes|YES)
        echo "Applying Telemetry resource to enable access logging for smtpd"
        cat <<EOF | kube apply -f - >/dev/null
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: smtpd-access-logs
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: smtpd
      app.kubernetes.io/instance: $RELEASE_NAME
  accessLogging:
    - providers:
        - name: envoy
EOF
        echo "Waiting ${TELEMETRY_SETTLE_SECONDS}s for the config push to reach the sidecar"
        sleep "$TELEMETRY_SETTLE_SECONDS"

        echo "Re-running probes so the connections appear in the log"
        probe "$TEST_HOST" "$EXCLUDED_PORT"
        probe "$CAPTURED_HOST" "$CAPTURED_PORT"

        # TCP access log entries are written when the connection closes.
        sleep "$STATS_SETTLE_SECONDS"

        LOG_WINDOW=$((TELEMETRY_SETTLE_SECONDS + STATS_SETTLE_SECONDS + 60))
        ACCESS_LOGS=$(kube logs "$POD_NAME" -c "$PROXY_CONTAINER" --since="${LOG_WINDOW}s" 2>/dev/null \
            | grep '^\[' || true)

        echo "--- outbound access log entries ---"
        OUTBOUND_LOGS=$(printf '%s\n' "$ACCESS_LOGS" | grep 'PassthroughCluster' || true)
        if [ -n "$OUTBOUND_LOGS" ]; then
            printf '%s\n' "$OUTBOUND_LOGS" | tail -n "$ACCESS_LOG_LINES"
        else
            echo "<none>"
        fi

        if printf '%s\n' "$OUTBOUND_LOGS" | grep -q ":$CAPTURED_PORT "; then
            pass "port $CAPTURED_PORT appears in the sidecar access log"
        else
            fail "port $CAPTURED_PORT did not appear in the sidecar access log"
        fi

        if printf '%s\n' "$OUTBOUND_LOGS" | grep -q ":$EXCLUDED_PORT "; then
            fail "port $EXCLUDED_PORT appears in the sidecar access log; it is not bypassing the mesh"
        else
            pass "port $EXCLUDED_PORT never reaches Envoy, so it is absent from the access log"
        fi

        echo "Remove with: kubectl --context $TARGET_CONTEXT -n $NAMESPACE delete telemetry smtpd-access-logs"
        ;;
    *)
        echo "Skipped. Set ENABLE_ACCESS_LOGS=true to apply a Telemetry resource and tail the sidecar log."
        ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
