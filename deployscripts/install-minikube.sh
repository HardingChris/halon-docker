#!/bin/sh
set -eu

# Configuration
IMAGE_COMPONENTS="api classifier clusterd dlpd expurgate policyd rated sasid savdid smtpd web"

RELEASE_NAME="${RELEASE_NAME:-halon}"
NAMESPACE="${NAMESPACE:-default}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
TARGET_CONTEXT="${TARGET_CONTEXT:-$MINIKUBE_PROFILE}"
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
MAIN_CHART_DIR="$REPO_ROOT/main"

ENV_VALUES="$REPO_ROOT/main/environments/minikube.yaml"
CHART_REF="$MAIN_CHART_DIR"
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

is_minikube_docker_daemon() {
    daemon_name=$(docker info --format '{{.Name}}' 2>/dev/null || true)
    [ "$daemon_name" = "$MINIKUBE_PROFILE" ]
}

require_local_image() {
    image_tag="$1"

    if docker image inspect "$image_tag" >/dev/null 2>&1; then
        return 0
    fi

    echo "ERROR: Required local image not found: $image_tag" >&2
    echo "install-minikube.sh only loads local halon/* tags." >&2
    echo "Run buildimages.sh and ensure it completes successfully before install." >&2
    exit 1
}

get_image_tag() {
    component="$1"
    readme="$REPO_ROOT/$component/README.md"

    if [ ! -f "$readme" ]; then
        echo "ERROR: Missing README: $readme" >&2
        return 1
    fi

    tag=$(sed -n 's/^docker build -t \([^ ]*:[0-9][^ ]*\) .*/\1/p' "$readme" | head -n 1)
    if [ -z "$tag" ]; then
        echo "ERROR: No versioned image tag found in $readme" >&2
        return 1
    fi

    printf '%s\n' "$tag"
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

    echo "Waiting for Elasticsearch secret '$ELASTICSEARCH_SECRET_NAME' in namespace '$ELASTIC_STACK_NAMESPACE' (timeout ${timeout}s)"

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

    echo "WARNING: Timed out waiting for Elasticsearch secret '$ELASTICSEARCH_SECRET_NAME' in namespace '$ELASTIC_STACK_NAMESPACE'."
    return 0
}

require_cmd helm
require_cmd kubectl
require_cmd minikube
require_cmd sed
require_cmd docker
require_cmd grep
require_cmd mktemp
require_cmd sleep

# Input checks
if [ ! -f "$ENV_VALUES" ]; then
    echo "ERROR: Missing values file: $ENV_VALUES" >&2
    exit 1
fi

# Cluster checks
if ! minikube -p "$MINIKUBE_PROFILE" status >/dev/null 2>&1; then
    echo "ERROR: Minikube profile '$MINIKUBE_PROFILE' is not running." >&2
    exit 1
fi

echo "Refreshing kubeconfig context for Minikube profile: $MINIKUBE_PROFILE"
minikube -p "$MINIKUBE_PROFILE" update-context >/dev/null
require_kube_context "$TARGET_CONTEXT"

if [ ! -f "$ELASTIC_INSTALL_SCRIPT" ]; then
    echo "ERROR: Missing Elasticsearch install helper: $ELASTIC_INSTALL_SCRIPT" >&2
    exit 1
fi

USE_MINIKUBE_DOCKER_DAEMON="false"
if is_minikube_docker_daemon; then
    USE_MINIKUBE_DOCKER_DAEMON="true"
    echo "Docker daemon is already Minikube profile '$MINIKUBE_PROFILE'; skipping image load step."
fi

echo "Building dependency artifacts into main/charts"
helm dependency build "$MAIN_CHART_DIR" >/dev/null

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

echo "Loading local images into Minikube"
for component in $IMAGE_COMPONENTS; do
    image_tag=$(get_image_tag "$component")
    require_local_image "$image_tag"

    if [ "$USE_MINIKUBE_DOCKER_DAEMON" = "true" ]; then
        echo "Using local image $image_tag from Minikube Docker daemon"
        continue
    fi

    echo "Loading $image_tag"
    minikube -p "$MINIKUBE_PROFILE" image load "$image_tag"

    if ! minikube -p "$MINIKUBE_PROFILE" image ls | grep -F -x "$image_tag" >/dev/null 2>&1; then
        echo "ERROR: minikube image load did not make '$image_tag' available in profile '$MINIKUBE_PROFILE'." >&2
        exit 1
    fi
done

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
        --kube-context "$TARGET_CONTEXT" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        -f "$ENV_VALUES" \
        --render-subchart-notes
fi

echo "Done. Release '$RELEASE_NAME' deployed to context '$TARGET_CONTEXT' in namespace '$NAMESPACE'."
