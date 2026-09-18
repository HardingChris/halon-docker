#!/bin/sh
set -eu

# Imports, publishes and schedules the AKS shutdown runbook in an existing
# Automation Account. Assumes the account, its managed identity and the role
# assignment on the AKS cluster already exist.

# Configuration
RESOURCE_GROUP="${RESOURCE_GROUP:-AppRelayPOC}"
AUTOMATION_ACCOUNT="${AUTOMATION_ACCOUNT:-aks-scheduler}"
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-$RESOURCE_GROUP}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-AppRelayPOC-aks}"
RUNBOOK_NAME="${RUNBOOK_NAME:-Stop-AksCluster}"
SCHEDULE_NAME="${SCHEDULE_NAME:-daily-aks-shutdown}"
SCHEDULE_TIME="${SCHEDULE_TIME:-18:00}"
SCHEDULE_TIMEZONE="${SCHEDULE_TIMEZONE:-Europe/London}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
MANAGED_IDENTITY_CLIENT_ID="${MANAGED_IDENTITY_CLIENT_ID:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNBOOK_FILE="$SCRIPT_DIR/automation/Stop-AksCluster.ps1"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1" >&2
        exit 1
    fi
}

require_cmd az
require_cmd python3

if [ ! -f "$RUNBOOK_FILE" ]; then
    echo "ERROR: Runbook file not found: $RUNBOOK_FILE" >&2
    exit 1
fi

if ! az account show >/dev/null 2>&1; then
    echo "No active Azure session detected. Starting interactive az login..."
    az login >/dev/null
fi

if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi

if ! az extension show --name automation >/dev/null 2>&1; then
    echo "Installing az automation extension..."
    az extension add --name automation --only-show-errors >/dev/null
fi

echo "Ensuring runbook '$RUNBOOK_NAME' exists..."
if ! az automation runbook show \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" >/dev/null 2>&1; then
    az automation runbook create \
        --resource-group "$RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --name "$RUNBOOK_NAME" \
        --type PowerShell \
        --location "$(az group show -n "$RESOURCE_GROUP" --query location -o tsv)" \
        --only-show-errors >/dev/null
fi

echo "Uploading runbook content..."
az automation runbook replace-content \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" \
    --content @"$RUNBOOK_FILE" \
    --only-show-errors >/dev/null

echo "Publishing runbook..."
az automation runbook publish \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" \
    --only-show-errors >/dev/null

# Schedules cannot start in the past; pick today or tomorrow at SCHEDULE_TIME.
START_TIME=$(python3 - "$SCHEDULE_TIME" <<'PY'
import datetime, sys

hour, minute = (int(part) for part in sys.argv[1].split(":"))
now = datetime.datetime.now()
start = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if start <= now + datetime.timedelta(minutes=10):
    start += datetime.timedelta(days=1)
print(start.strftime("%Y-%m-%d %H:%M:%S"))
PY
)

echo "Ensuring daily schedule '$SCHEDULE_NAME' at $START_TIME ($SCHEDULE_TIMEZONE)..."
if ! az automation schedule show \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$SCHEDULE_NAME" >/dev/null 2>&1; then
    az automation schedule create \
        --resource-group "$RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --name "$SCHEDULE_NAME" \
        --frequency Day \
        --interval 1 \
        --start-time "$START_TIME" \
        --time-zone "$SCHEDULE_TIMEZONE" \
        --only-show-errors >/dev/null
fi

# There is no az automation job-schedule command, so link via the ARM API.
JOB_SCHEDULE_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
JOB_SCHEDULE_BODY=$(AKS_RESOURCE_GROUP="$AKS_RESOURCE_GROUP" \
    AKS_CLUSTER_NAME="$AKS_CLUSTER_NAME" \
    SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
    MANAGED_IDENTITY_CLIENT_ID="$MANAGED_IDENTITY_CLIENT_ID" \
    RUNBOOK_NAME="$RUNBOOK_NAME" \
    SCHEDULE_NAME="$SCHEDULE_NAME" \
    python3 - <<'PY'
import json, os

parameters = {
    "ResourceGroupName": os.environ["AKS_RESOURCE_GROUP"],
    "ClusterName": os.environ["AKS_CLUSTER_NAME"],
    "SubscriptionId": os.environ["SUBSCRIPTION_ID"],
}
client_id = os.environ.get("MANAGED_IDENTITY_CLIENT_ID", "")
if client_id:
    parameters["ManagedIdentityClientId"] = client_id

print(json.dumps({
    "properties": {
        "schedule": {"name": os.environ["SCHEDULE_NAME"]},
        "runbook": {"name": os.environ["RUNBOOK_NAME"]},
        "parameters": parameters,
    }
}))
PY
)

echo "Linking schedule to runbook..."
az rest --method put \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT/jobSchedules/$JOB_SCHEDULE_ID?api-version=2023-11-01" \
    --body "$JOB_SCHEDULE_BODY" \
    --only-show-errors >/dev/null

echo "Done. '$RUNBOOK_NAME' will stop '$AKS_CLUSTER_NAME' daily at $SCHEDULE_TIME $SCHEDULE_TIMEZONE."
