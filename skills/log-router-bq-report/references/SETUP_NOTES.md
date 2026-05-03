# Setup Notes — Log Router to BigQuery

## Architecture

```
DinoQuest2 (Cloud Run)
        │
        │ stderr / stdout / request logs
        ▼
Cloud Logging (Log Router)
        │
        │  Sink: dinoquest2-bq-sink
        │  Filter: resource.type="cloud_run_revision"
        │          AND resource.labels.service_name="dinoquest2"
        ▼
BigQuery Dataset: dinoquest2_logs
        │
        │  Table: run_googleapis_com_requests_YYYYMMDD (partitioned by day)
        ▼
BigQuery MCP → execute_sql → Report
```

## IAM Requirements

| Principal | Role | Scope | Why |
|---|---|---|---|
| Executing user / agent | `roles/logging.admin` | Project | To create/manage sinks |
| Executing user / agent | `roles/bigquery.dataEditor` + `roles/bigquery.user` | Project | To create datasets and query tables |
| Sink `writerIdentity` (auto-generated SA) | `roles/bigquery.dataEditor` | Dataset `dinoquest2_logs` | Allows Log Router to insert rows into BigQuery |

## Sink `writerIdentity`

After running `create_sink.sh`, Google generates a dedicated service account for the sink.
It looks like:
```
serviceAccount:p<PROJECT_NUMBER>-<HASH>@gcp-sa-logging.iam.gserviceaccount.com
```
`grant_sink_permissions.sh` automatically retrieves and grants this identity the required role.

## BigQuery Table Naming

Cloud Logging creates partitioned tables named by log type and date, for example:
- `run_googleapis_com_requests_20250414` — HTTP request logs
- `run_googleapis_com_stderr_20250414` — stderr/stdout container logs

The skill's Phase 2 queries use `list_table_ids` via BigQuery MCP to discover the correct
table name dynamically before running SQL.

## Why `google-cloud-logging` MCP Cannot Create Sinks

The official Google remote MCP server at `logging.googleapis.com/mcp` exposes read-only tools
(`list_log_entries`, `list_log_names`, `list_buckets`). Sink management is not included in the
current tool manifest. The `scripts/create_sink.sh` script bridges this gap using `gcloud` CLI.

## Estimated Costs

| Resource | Cost |
|---|---|
| Log export (sink) | Free up to 50 GiB/month |
| BigQuery storage | ~$0.02/GB/month |
| BigQuery queries (`execute_sql`) | $5/TB scanned (on-demand) |
| Partitioned tables | Reduces scan cost significantly |
