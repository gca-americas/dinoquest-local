#!/usr/bin/env bash
# check_sink.sh — Checks if the dinoquest2-bq-sink Log Router sink exists.
# Usage: bash check_sink.sh <PROJECT_ID>
set -euo pipefail

PROJECT_ID="${1:?Error: PROJECT_ID is required. Usage: bash check_sink.sh <PROJECT_ID>}"
SINK_NAME="dinoquest-bq-sink"

echo "=== Checking Log Router Sink ==="
echo "Project:   $PROJECT_ID"
echo "Sink Name: $SINK_NAME"
echo ""

if gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" &>/dev/null; then
  echo "✅ Sink '$SINK_NAME' already exists."
  echo ""
  echo "--- Sink Details ---"
  gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID"
  echo ""
  echo "STATUS=exists"
else
  echo "ℹ️  Sink '$SINK_NAME' does not exist yet."
  echo "STATUS=not_found"
fi
