#!/usr/bin/env bash
# create_bq_dataset.sh — Creates the dinoquest2_logs BigQuery dataset if it doesn't exist.
# Usage: bash create_bq_dataset.sh <PROJECT_ID>
set -euo pipefail

PROJECT_ID="${1:?Error: PROJECT_ID is required. Usage: bash create_bq_dataset.sh <PROJECT_ID>}"
DATASET_ID="dinoquest_logs"
REGION="us-central1"

echo "=== Creating BigQuery Dataset ==="
echo "Project:  $PROJECT_ID"
echo "Dataset:  $DATASET_ID"
echo "Location: $REGION"
echo ""

# Check if dataset already exists
if bq show --project_id="$PROJECT_ID" "$DATASET_ID" &>/dev/null; then
  echo "✅ Dataset '$DATASET_ID' already exists. Skipping creation."
else
  bq mk \
    --project_id="$PROJECT_ID" \
    --dataset \
    --location="$REGION" \
    --description="DinoQuest2 Cloud Run server logs exported via Log Router" \
    "$DATASET_ID"
  echo "✅ Dataset '$DATASET_ID' created in $REGION."
fi
