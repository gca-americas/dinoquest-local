#!/usr/bin/env bash
# create_sink.sh — Creates a Log Router sink to export DinoQuest2 Cloud Run logs to BigQuery.
# Usage: bash create_sink.sh <PROJECT_ID>
set -euo pipefail

PROJECT_ID="${1:?Error: PROJECT_ID is required. Usage: bash create_sink.sh <PROJECT_ID>}"
SINK_NAME="dinoquest-bq-sink"
DATASET_ID="dinoquest_logs"
DESTINATION="bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET_ID}"
# Filter: only Cloud Run request logs and stderr from the dinoquest2 service
LOG_FILTER='resource.type="cloud_run_revision" AND resource.labels.service_name="dinoquest"'

echo "=== Creating Log Router Sink ==="
echo "Project:     $PROJECT_ID"
echo "Sink Name:   $SINK_NAME"
echo "Destination: $DESTINATION"
echo "Filter:      $LOG_FILTER"
echo ""

gcloud logging sinks create "$SINK_NAME" \
  "$DESTINATION" \
  --log-filter="$LOG_FILTER" \
  --project="$PROJECT_ID" \
  --use-partitioned-tables

echo ""
echo "✅ Sink '$SINK_NAME' created successfully."
echo ""
echo "--- Writer Identity (needed for IAM grant) ---"
WRITER_IDENTITY=$(gcloud logging sinks describe "$SINK_NAME" \
  --project="$PROJECT_ID" \
  --format="value(writerIdentity)")
echo "writerIdentity: $WRITER_IDENTITY"
echo ""
echo "⚠️  NEXT STEP: Run grant_sink_permissions.sh to give this identity BigQuery write access."
echo "WRITER_IDENTITY=$WRITER_IDENTITY"
