#!/usr/bin/env bash
# grant_sink_permissions.sh — Grants the Log Router sink's writerIdentity bigquery.dataEditor
#                              on the dinoquest2_logs dataset so it can insert log rows.
# Usage: bash grant_sink_permissions.sh <PROJECT_ID>
set -euo pipefail

PROJECT_ID="${1:?Error: PROJECT_ID is required. Usage: bash grant_sink_permissions.sh <PROJECT_ID>}"
SINK_NAME="dinoquest-bq-sink"
DATASET_ID="dinoquest_logs"

echo "=== Granting BigQuery Permissions to Sink Writer ==="
echo "Project: $PROJECT_ID"
echo "Sink:    $SINK_NAME"
echo "Dataset: $DATASET_ID"
echo ""

# Resolve the writerIdentity for this sink
WRITER_IDENTITY=$(gcloud logging sinks describe "$SINK_NAME" \
  --project="$PROJECT_ID" \
  --format="value(writerIdentity)")

if [[ -z "$WRITER_IDENTITY" ]]; then
  echo "❌ Could not resolve writerIdentity for sink '$SINK_NAME'. Does the sink exist?"
  exit 1
fi

echo "Writer Identity: $WRITER_IDENTITY"
echo ""

# Grant bigquery.dataEditor on the dataset
bq query --nouse_legacy_sql --project_id="$PROJECT_ID" \
  "GRANT \`roles/bigquery.dataEditor\` ON SCHEMA \`${PROJECT_ID}.${DATASET_ID}\` TO '${WRITER_IDENTITY}'"

echo ""
echo "✅ Granted roles/bigquery.dataEditor to $WRITER_IDENTITY on dataset $DATASET_ID."
echo "ℹ️  Logs should begin flowing within 1–2 minutes."
