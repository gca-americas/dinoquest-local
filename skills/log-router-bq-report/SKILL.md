---
name: log-router-bq-report
description: >
  Sets up a Cloud Logging Log Router sink to stream live Cloud Run server logs into a BigQuery
  dataset, then queries BigQuery via MCP to generate a quick traffic and error report, and a
  game analytics report with feature insights. Use when asked to route Cloud Run logs to BigQuery,
  set up log export, analyze server logs, generate a log report from BigQuery, or surface feature
  ideas from game event data.
license: Proprietary
compatibility: >
  Requires google-cloud-logging and google-bigquery MCP servers to be enabled in mcp_config.json.
  The sink creation step requires gcloud CLI (authenticated) to be available in the shell.
  Designed for Gemini/Antigravity agent with access to Bash and MCP tools.
metadata:
  author: <SERVICE_NAME>-team
  version: "1.0"
  service: <SERVICE_NAME>
  region: us-central1
allowed-tools: mcp__google-cloud-logging mcp__google-bigquery Bash
---

## Configuration

> **Edit these values to adapt this skill to your project.**

| Variable | Default | Description |
|---|---|---|
| `SERVICE_NAME` | `dinoquest` | Cloud Run service name |
| `BQ_DATASET` | `dinoquest_logs` | BigQuery dataset name for log export |
| `LOG_SINK_NAME` | `dinoquest-bq-sink` | Cloud Logging sink name |

---

## Overview

Before doing any work, output this pipeline flow diagram so the user can see what is coming:

```
  DinoQuest Log Router + BigQuery Report Pipeline
  ══════════════════════════════════════════════════

  ┌─────────────────────────────┐
  │  Resolve GCP Project        │
  └──────────────┬──────────────┘
                 │
                 ▼
  ┌─────────────────────────────┐
  │  Phase 1: Log Router Setup  │
  │  Check if sink exists       │
  └──────────────┬──────────────┘
                 │
         ┌───────┴────────┐
         ▼                ▼
    [✔] exists        [new]
    skip to           Create BQ dataset
    Phase 2           Create sink
                      Grant BQ permissions
         └───────┬────────┘
                 │
                 ▼
  ┌─────────────────────────────┐
  │  Phase 2: BQ Log Report     │
  │  Discover log table         │
  │  Query: traffic summary     │
  │  Query: top error messages  │
  │  Output report              │
  └──────────────┬──────────────┘
                 │
                 ▼
  ┌─────────────────────────────┐
  │  Phase 3: Feature Insights  │
  │  Win rate by dino type      │
  │  Coins per outcome          │
  │  Dino reuse rate            │
  │  Habitat × Diet → Type      │
  └──────────────┬──────────────┘
                 │
                 ▼
  ┌─────────────────────────────┐
  │  Generate HTML Report       │
  │  Save to reports/           │
  │  Print file path            │
  └─────────────────────────────┘

  ══════════════════════════════════════════════════
```

This skill has three phases:

1. **Setup** — Creates a Cloud Logging Log Router sink to continuously stream DinoQuest2 Cloud Run
   logs into a BigQuery dataset (idempotent: skipped if the sink already exists).
2. **Report** — Queries the BigQuery log table via MCP to produce a live traffic and error summary.
3. **Feature Insights** — Analyzes game event telemetry (`DINO_CREATED`, `GAME_START`, `GAME_END`)
   to surface data-driven product ideas around personalization, difficulty, retention, and progression.

See [references/SETUP_NOTES.md](references/SETUP_NOTES.md) for architecture details and IAM notes.

---

## Phase 1: Set Up the Log Router Sink

### Step 1.1 — Resolve Project ID

**Try MCP first.** Use the `google-resource-manager` MCP server to search for the active project:

```
Tool: google-resource-manager → search_projects
```

Extract the `projectId` from the first result that matches the DinoQuest project (look for
`dinoquest` in the name or ID, or the project associated with the current credentials).

**If the MCP call fails or returns no results**, fall back to CLI:

```bash
gcloud config get-value project
```

Store the resolved value as `PROJECT_ID` for all subsequent steps.

---

### Step 1.2 — Check if Sink Already Exists

**Try MCP first.** Use the `google-bigquery` MCP server to check whether the destination dataset
already has log tables (which proves the sink has been flowing data):

```
Tool: google-bigquery → list_table_ids
Parameters:
  - project: <PROJECT_ID>
  - dataset: <BQ_DATASET>
```

- If the dataset exists and contains `run_googleapis_com_requests_*` tables → sink already exists,
  **skip to Phase 2**.
- If the MCP call errors or the dataset is missing → fall back to CLI to confirm:

```bash
bash scripts/check_sink.sh "$PROJECT_ID"
```

- If the sink `<LOG_SINK_NAME>` exists → **skip to Phase 2**.
- If it does not exist → **continue to Step 1.3**.

---

### Step 1.3 — Create the BigQuery Dataset (if needed)

Use the `google-bigquery` MCP server to check whether the target dataset exists:

```
Tool: google-bigquery → list_dataset_ids
Parameters:
  - project: <PROJECT_ID>
```

If the dataset `<BQ_DATASET>` is **not** in the list, create it:

```bash
bash scripts/create_bq_dataset.sh "$PROJECT_ID"
```

---

### Step 1.4 — Create the Log Router Sink

Run the sink creation script:

```bash
bash scripts/create_sink.sh "$PROJECT_ID"
```

This script:
- Creates a sink named `<LOG_SINK_NAME>`
- Filters to Cloud Run logs for the `<SERVICE_NAME>` service
- Destinations to `bigquery.googleapis.com/projects/$PROJECT_ID/datasets/<BQ_DATASET>`
- Captures the sink's `writerIdentity` output

---

### Step 1.5 — Grant BigQuery Permissions to the Sink Writer

After the sink is created, the Log Router generates a `writerIdentity` service account.
Grant it write access to the dataset:

```bash
bash scripts/grant_sink_permissions.sh "$PROJECT_ID"
```

This grants the `writerIdentity` the `roles/bigquery.dataEditor` role on the `<BQ_DATASET>`
dataset so the sink can insert rows.

> **Note:** Logs will begin flowing within ~1–2 minutes of the sink being created. If you run the
> report immediately after setup, results may be empty — wait a few minutes for data to populate,
> or proceed to Phase 2 to check existing data.

---

## Phase 2: Generate the BigQuery Log Report

### Step 2.1 — Discover the Log Table

Use the `google-bigquery` MCP server to confirm the log table exists in the dataset:

```
Tool: google-bigquery → list_table_ids
Parameters:
  - project: <PROJECT_ID>
  - dataset: <BQ_DATASET>
```

Cloud Logging creates tables named by date (e.g., `run_googleapis_com_requests_YYYYMMDD`).
Identify the most recent table name for use in queries.

---

### Step 2.2 — Query: Request Rate Summary (Last Hour)

```
Tool: google-bigquery → execute_sql
SQL:
  SELECT
    FORMAT_TIMESTAMP('%Y-%m-%d %H:%M', timestamp, 'UTC') AS minute,
    COUNT(*) AS request_count,
    COUNTIF(httpRequest.status >= 500) AS server_errors,
    COUNTIF(httpRequest.status >= 400 AND httpRequest.status < 500) AS client_errors,
    ROUND(AVG(httpRequest.latency * 1000), 0) AS avg_latency_ms
  FROM `<PROJECT_ID>.<BQ_DATASET>.<TABLE_NAME>`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 MINUTE)
  GROUP BY minute
  ORDER BY minute DESC
  LIMIT 30
```

---

### Step 2.3 — Query: Top Error Messages (Last Hour)

```
Tool: google-bigquery → execute_sql
SQL:
  SELECT
    textPayload AS error_message,
    severity,
    COUNT(*) AS occurrences
  FROM `<PROJECT_ID>.<BQ_DATASET>.<TABLE_NAME>`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 MINUTE)
    AND severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
  GROUP BY error_message, severity
  ORDER BY occurrences DESC
  LIMIT 10
```

---

### Step 2.4 — Report Results

Output the following structured report:

```
=== DinoQuest2 Log Report (BigQuery) ===
Project:    <PROJECT_ID>
Dataset:    <BQ_DATASET>
Table:      <TABLE_NAME>
Report Time: <ISO-8601 timestamp>
Window:     Last 60 minutes

--- Traffic Summary ---
[Table: minute | request_count | server_errors | client_errors | avg_latency_ms]

--- Top Errors ---
[Table: error_message | severity | occurrences]

--- Sink Status ---
Sink Name:       <LOG_SINK_NAME>
Created:         YES / already existed
Writer Identity: <writerIdentity email>
```

---

---

## Phase 3: Game Feature Insights

Analyzes game events in `run_googleapis_com_stdout_YYYYMMDD`. The backend logs via `print(json.dumps({...}))`,
so events land in the `textPayload` column as plain JSON strings — **there is no `jsonPayload` column**.
Extract fields with `JSON_VALUE(textPayload, '$.field')`.

- **Booleans** (`won`, `is_reuse`): compare as strings — `JSON_VALUE(textPayload, '$.won') = 'true'`
- **Numerics** (`score`, `coins`, `speed`): `SAFE_CAST(JSON_VALUE(textPayload, '$.score') AS FLOAT64)`
- **Filter for events**: `WHERE JSON_VALUE(textPayload, '$.event') = 'GAME_END'`

Run all four queries in parallel. Use the most recent stdout table (same date suffix as Phase 2).

---

### Step 3.1 — Query: Win Rate by Dino Type (Difficulty Tuning)

If Agile win rate is significantly higher than other types, rebalancing is needed.

```sql
SELECT
  JSON_VALUE(textPayload, '$.dino_type') AS dino_type,
  COUNT(*) AS total_games,
  COUNTIF(JSON_VALUE(textPayload, '$.won') = 'true') AS wins,
  ROUND(COUNTIF(JSON_VALUE(textPayload, '$.won') = 'true') / COUNT(*) * 100, 1) AS win_rate_pct,
  ROUND(AVG(SAFE_CAST(JSON_VALUE(textPayload, '$.score') AS FLOAT64)), 0) AS avg_score,
  ROUND(AVG(SAFE_CAST(JSON_VALUE(textPayload, '$.speed') AS FLOAT64)), 2) AS avg_speed
FROM `<PROJECT_ID>.<BQ_DATASET>.<STDOUT_TABLE>`
WHERE JSON_VALUE(textPayload, '$.event') = 'GAME_END'
  AND JSON_VALUE(textPayload, '$.dino_type') IS NOT NULL
GROUP BY dino_type
ORDER BY win_rate_pct DESC
```

**Signal:** win_rate_pct > 70% for a single type → rebalance that type's speed/stats.

---

### Step 3.2 — Query: Coins per Outcome (Progression Currency)

Low coin yield on wins → no incentive to keep playing.

```sql
SELECT
  JSON_VALUE(textPayload, '$.won') = 'true' AS won,
  COUNT(*) AS games,
  ROUND(AVG(SAFE_CAST(JSON_VALUE(textPayload, '$.coins') AS FLOAT64)), 2) AS avg_coins,
  MIN(SAFE_CAST(JSON_VALUE(textPayload, '$.coins') AS FLOAT64)) AS min_coins,
  MAX(SAFE_CAST(JSON_VALUE(textPayload, '$.coins') AS FLOAT64)) AS max_coins
FROM `<PROJECT_ID>.<BQ_DATASET>.<STDOUT_TABLE>`
WHERE JSON_VALUE(textPayload, '$.event') = 'GAME_END'
GROUP BY won
```

**Signal:** avg_coins on win ≤ 3 → consider a coin boost or streak bonus to drive retention.

---

### Step 3.3 — Query: Dino Reuse Rate (Personalization Signal)

High reuse of specific dinos reveals player favorites and attachment patterns.

```sql
SELECT
  JSON_VALUE(textPayload, '$.dino_name') AS dino_name,
  JSON_VALUE(textPayload, '$.dino_type') AS dino_type,
  COUNT(*) AS total_starts,
  COUNTIF(JSON_VALUE(textPayload, '$.is_reuse') = 'true') AS reuse_starts,
  COUNTIF(JSON_VALUE(textPayload, '$.is_reuse') = 'false') AS fresh_starts
FROM `<PROJECT_ID>.<BQ_DATASET>.<STDOUT_TABLE>`
WHERE JSON_VALUE(textPayload, '$.event') = 'GAME_START'
  AND JSON_VALUE(textPayload, '$.dino_name') IS NOT NULL
GROUP BY dino_name, dino_type
ORDER BY reuse_starts DESC
LIMIT 10
```

**Signal:** Dinos with reuse_starts > 3 → show "your dino" personality card to returning players.

---

### Step 3.4 — Query: Habitat + Diet → Dino Type Correlation (Personalization Engine)

Reveals whether habitat/diet choices reliably predict dino type — enables previewing type before confirm.

```sql
SELECT
  JSON_VALUE(textPayload, '$.habitat') AS habitat,
  JSON_VALUE(textPayload, '$.diet') AS diet,
  JSON_VALUE(textPayload, '$.generated_type') AS dino_type,
  COUNT(*) AS occurrences
FROM `<PROJECT_ID>.<BQ_DATASET>.<STDOUT_TABLE>`
WHERE JSON_VALUE(textPayload, '$.event') = 'DINO_CREATED'
GROUP BY habitat, diet, dino_type
ORDER BY occurrences DESC
LIMIT 20
```

**Signal:** A habitat+diet combo that always maps to one type (100% of rows) is deterministic enough to show a type preview before the user confirms.

> **Note:** `DINO_CREATED` only fires when users generate a new dino via `/api/generate`. If the
> table was just created today, this may return empty. Always use the 7-day wildcard:
> ```sql
> FROM `<PROJECT_ID>.<BQ_DATASET>.run_googleapis_com_stdout_*`
> WHERE _TABLE_SUFFIX >= FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
>   AND JSON_VALUE(textPayload, '$.event') = 'DINO_CREATED'
> ```

---

### Step 3.5 — Generate Interactive HTML Report

Instead of printing plain text, generate a **standalone animated HTML file** and save it to
`reports/dinoquest-insights-<YYYYMMDD-HHmmss>.html` (create the `reports/` directory if it
doesn't exist). After writing the file, print:

```
Report saved → reports/dinoquest-insights-<timestamp>.html
Open it in any browser to view the interactive dashboard.
```

---

#### HTML template

Write the file using the exact structure below. Replace every `/* DATA */` placeholder with
real values from the query results. The file must be fully self-contained (no external files —
Chart.js and Google Fonts are loaded from CDN).

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>🦕 DinoQuest2 Insights</title>
<link href="https://fonts.googleapis.com/css2?family=Fredoka+One&family=Nunito:wght@400;700;900&display=swap" rel="stylesheet"/>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --green:#16a34a; --green-light:#f0fdf4; --green-dark:#166534;
    --yellow:#facc15; --yellow-dark:#eab308; --orange:#f97316;
    --red:#ef4444; --blue:#2563eb; --purple:#a855f7; --pink:#ec4899;
    --bg:#fdfcf0; --card:#ffffff; --shadow:0 8px 32px rgba(0,0,0,.12);
  }
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:var(--bg);font-family:'Nunito',sans-serif;overflow-x:hidden;}

  /* ── floating dino emojis background ── */
  .dino-bg{position:fixed;inset:0;pointer-events:none;z-index:0;overflow:hidden;}
  .dino-bg span{position:absolute;font-size:2.5rem;opacity:.08;animation:floatUp linear infinite;}
  @keyframes floatUp{0%{transform:translateY(110vh) rotate(0deg);}100%{transform:translateY(-10vh) rotate(360deg);}}

  /* ── hero header ── */
  header{
    position:relative;z-index:1;text-align:center;padding:3rem 1rem 2rem;
    background:linear-gradient(135deg,#166534 0%,#16a34a 50%,#22c55e 100%);
    border-bottom:6px solid #facc15;overflow:hidden;
  }
  header::before{
    content:'';position:absolute;inset:0;
    background:radial-gradient(circle at 20% 50%,rgba(250,204,21,.15) 0%,transparent 60%),
               radial-gradient(circle at 80% 50%,rgba(34,197,94,.2) 0%,transparent 60%);
  }
  .header-title{
    font-family:'Fredoka One',cursive;font-size:clamp(2.5rem,6vw,4.5rem);
    color:#fff;letter-spacing:-.02em;text-shadow:4px 4px 0 #166534;
    animation:titleBounce .8s cubic-bezier(.36,.07,.19,.97) both;
  }
  @keyframes titleBounce{0%{transform:scale(0) rotate(-10deg);}60%{transform:scale(1.15) rotate(3deg);}100%{transform:scale(1) rotate(0deg);}}
  .header-sub{color:#dcfce7;font-size:1.1rem;font-weight:700;margin-top:.5rem;opacity:.9;}
  .header-badge{
    display:inline-block;background:#facc15;color:#713f12;
    font-weight:900;font-size:.85rem;padding:.3rem .9rem;border-radius:9999px;
    margin-top:1rem;border:3px solid #eab308;letter-spacing:.05em;
    animation:pulse 2s ease-in-out infinite;
  }
  @keyframes pulse{0%,100%{transform:scale(1);}50%{transform:scale(1.06);}}

  /* ── main grid ── */
  main{position:relative;z-index:1;max-width:1200px;margin:0 auto;padding:2rem 1rem 4rem;}
  .section-title{
    font-family:'Fredoka One',cursive;font-size:1.8rem;color:var(--green-dark);
    margin:2.5rem 0 1rem;display:flex;align-items:center;gap:.5rem;
  }
  .section-title .pill{
    font-family:'Nunito',sans-serif;font-size:.75rem;font-weight:900;
    background:var(--green);color:#fff;padding:.2rem .7rem;
    border-radius:9999px;letter-spacing:.08em;
  }

  /* ── cards ── */
  .card{
    background:var(--card);border-radius:1.5rem;
    border:3px solid #e5e7eb;box-shadow:var(--shadow);
    padding:1.5rem;transition:transform .2s,box-shadow .2s;
    animation:cardIn .5s ease both;
  }
  .card:hover{transform:translateY(-4px) rotate(.3deg);box-shadow:0 16px 48px rgba(0,0,0,.18);}
  @keyframes cardIn{from{opacity:0;transform:translateY(24px);}to{opacity:1;transform:translateY(0);}}
  .cards-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:1.25rem;margin-bottom:1.5rem;}

  /* ── stat bubble ── */
  .stat-bubble{text-align:center;}
  .stat-bubble .value{
    font-family:'Fredoka One',cursive;font-size:2.8rem;line-height:1;
    background:linear-gradient(135deg,var(--green),var(--yellow-dark));
    -webkit-background-clip:text;-webkit-text-fill-color:transparent;
    animation:countUp .8s ease both;
  }
  @keyframes countUp{from{opacity:0;transform:scale(.5);}to{opacity:1;transform:scale(1);}}
  .stat-bubble .label{font-size:.8rem;font-weight:900;color:#6b7280;letter-spacing:.1em;text-transform:uppercase;margin-top:.3rem;}
  .stat-bubble .sub{font-size:.75rem;color:#9ca3af;margin-top:.15rem;}

  /* ── chart containers ── */
  .chart-wrap{position:relative;height:280px;width:100%;}
  .chart-card{padding:1.5rem 1.5rem 1rem;}

  /* ── table ── */
  .dino-table{width:100%;border-collapse:separate;border-spacing:0;font-size:.9rem;}
  .dino-table thead tr{background:linear-gradient(90deg,var(--green-dark),var(--green));}
  .dino-table thead th{color:#fff;font-weight:900;padding:.7rem 1rem;text-align:left;letter-spacing:.05em;}
  .dino-table thead th:first-child{border-radius:.75rem 0 0 .75rem;}
  .dino-table thead th:last-child{border-radius:0 .75rem .75rem 0;}
  .dino-table tbody tr{transition:background .15s;}
  .dino-table tbody tr:hover{background:#f0fdf4;}
  .dino-table tbody tr:nth-child(even){background:#fafafa;}
  .dino-table tbody td{padding:.65rem 1rem;border-bottom:1px solid #e5e7eb;}

  /* ── win-rate bar ── */
  .winbar{height:10px;border-radius:9999px;background:#e5e7eb;overflow:hidden;min-width:80px;}
  .winbar-fill{height:100%;border-radius:9999px;transition:width 1s cubic-bezier(.4,0,.2,1);
    background:linear-gradient(90deg,#22c55e,#facc15);}

  /* ── signal badge ── */
  .signal{
    display:inline-flex;align-items:center;gap:.4rem;
    font-size:.8rem;font-weight:900;padding:.35rem .8rem;
    border-radius:9999px;margin-top:1rem;border:2px solid transparent;
  }
  .signal.ok{background:#dcfce7;color:#166534;border-color:#22c55e;}
  .signal.warn{background:#fef3c7;color:#92400e;border-color:#facc15;}
  .signal.alert{background:#fee2e2;color:#991b1b;border-color:#ef4444;}

  /* ── dino type badge ── */
  .type-badge{
    display:inline-block;font-size:.75rem;font-weight:900;
    padding:.2rem .6rem;border-radius:9999px;letter-spacing:.05em;
  }
  .type-Agile{background:#dcfce7;color:#166534;border:2px solid #22c55e;}
  .type-Tank{background:#dbeafe;color:#1e40af;border:2px solid #3b82f6;}
  .type-Speedy{background:#fef3c7;color:#92400e;border:2px solid #facc15;}
  .type-Balanced{background:#f3e8ff;color:#6b21a8;border:2px solid #a855f7;}
  .type-default{background:#f3f4f6;color:#374151;border:2px solid #9ca3af;}

  /* ── habitat matrix ── */
  .matrix-grid{display:grid;gap:.5rem;}
  .matrix-row{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap;}
  .matrix-cell{
    font-size:.78rem;font-weight:700;padding:.3rem .65rem;
    border-radius:.75rem;border:2px solid;cursor:default;
    transition:transform .15s;
  }
  .matrix-cell:hover{transform:scale(1.08) rotate(1deg);}

  /* ── traffic sparkline section ── */
  .traffic-header{display:flex;gap:1rem;flex-wrap:wrap;margin-bottom:1rem;}
  .traffic-kpi{
    background:linear-gradient(135deg,var(--green-dark),var(--green));
    color:#fff;border-radius:1rem;padding:.8rem 1.2rem;flex:1;min-width:140px;
    border:3px solid #22c55e;text-align:center;
  }
  .traffic-kpi .kv{font-family:'Fredoka One',cursive;font-size:1.8rem;}
  .traffic-kpi .kl{font-size:.75rem;font-weight:700;opacity:.85;letter-spacing:.08em;text-transform:uppercase;}

  /* ── footer ── */
  footer{
    position:relative;z-index:1;text-align:center;padding:2rem;
    font-size:.8rem;color:#9ca3af;font-weight:700;letter-spacing:.05em;
  }

  /* ── wiggle on hover for emoji icons ── */
  .wiggle:hover{animation:wiggle .4s ease;}
  @keyframes wiggle{0%,100%{transform:rotate(0);}25%{transform:rotate(-12deg);}75%{transform:rotate(12deg);}}

  /* ── confetti burst (CSS only, fires on load) ── */
  .confetti-wrap{position:fixed;top:0;left:50%;transform:translateX(-50%);pointer-events:none;z-index:999;}
  .confetti-piece{
    position:absolute;width:10px;height:10px;border-radius:2px;
    animation:confettiFall 2.5s ease-in forwards;
  }
  @keyframes confettiFall{
    0%{transform:translateY(0) rotate(0deg);opacity:1;}
    100%{transform:translateY(100vh) rotate(720deg);opacity:0;}
  }
</style>
</head>
<body>

<!-- floating dino background -->
<div class="dino-bg" id="dinoBg"></div>

<!-- confetti -->
<div class="confetti-wrap" id="confetti"></div>

<!-- ══ HEADER ══ -->
<header>
  <div class="header-title">🦕 DinoQuest2 Insights</div>
  <div class="header-sub">Live Game Analytics Dashboard</div>
  <div class="header-badge">📅 Report generated: /* REPORT_TIME */</div>
</header>

<main>

  <!-- ══ SECTION 1: TRAFFIC ══ -->
  <div class="section-title">🌐 Traffic Overview <span class="pill">LAST 60 MIN</span></div>

  <div class="traffic-header">
    <div class="traffic-kpi"><div class="kv">/* TOTAL_REQUESTS */</div><div class="kl">Total Requests</div></div>
    <div class="traffic-kpi" style="background:linear-gradient(135deg,#ef4444,#f97316);border-color:#f97316;">
      <div class="kv">/* TOTAL_ERRORS */</div><div class="kl">Server Errors</div>
    </div>
    <div class="traffic-kpi" style="background:linear-gradient(135deg,#2563eb,#7c3aed);border-color:#7c3aed;">
      <div class="kv">/* AVG_LATENCY */ms</div><div class="kl">Avg Latency</div>
    </div>
  </div>

  <div class="card chart-card">
    <div class="chart-wrap"><canvas id="trafficChart"></canvas></div>
  </div>

  <!-- ══ SECTION 2: WIN RATE ══ -->
  <div class="section-title">🏆 Win Rate by Dino Type <span class="pill">DIFFICULTY</span></div>
  <div class="cards-grid" id="winRateCards">
    <!-- generated by JS -->
  </div>
  <div class="card chart-card">
    <div class="chart-wrap"><canvas id="winRateChart"></canvas></div>
  </div>

  <!-- ══ SECTION 3: COINS ══ -->
  <div class="section-title">🪙 Coins per Outcome <span class="pill">PROGRESSION</span></div>
  <div class="cards-grid">
    <div class="card stat-bubble" style="border-color:#22c55e;">
      <div class="value" style="font-size:3rem;">/* WIN_AVG_COINS */</div>
      <div class="label">Avg Coins on WIN</div>
      <div class="sub">/* WIN_GAMES */ games</div>
    </div>
    <div class="card stat-bubble" style="border-color:#ef4444;">
      <div class="value" style="background:linear-gradient(135deg,#ef4444,#f97316);-webkit-background-clip:text;-webkit-text-fill-color:transparent;font-size:3rem;">/* LOSS_AVG_COINS */</div>
      <div class="label">Avg Coins on LOSS</div>
      <div class="sub">/* LOSS_GAMES */ games</div>
    </div>
    <div class="card chart-card">
      <div class="chart-wrap" style="height:200px;"><canvas id="coinsChart"></canvas></div>
    </div>
  </div>
  <div id="coinSignal"></div>

  <!-- ══ SECTION 4: REUSE ══ -->
  <div class="section-title">🔁 Top Reused Dinos <span class="pill">PERSONALIZATION</span></div>
  <div class="card" style="overflow-x:auto;">
    <table class="dino-table" id="reuseTable">
      <thead><tr>
        <th>🦕 Dino Name</th><th>Type</th>
        <th>Total Starts</th><th>Reuse</th><th>Fresh</th><th>Reuse Rate</th>
      </tr></thead>
      <tbody id="reuseBody"></tbody>
    </table>
  </div>

  <!-- ══ SECTION 5: HABITAT MATRIX ══ -->
  <div class="section-title">🗺️ Habitat × Diet → Type <span class="pill">ENGINE</span></div>
  <div class="card" id="matrixCard">
    <div id="habitatMatrix"></div>
  </div>

</main>

<footer>🦖 DinoQuest2 Analytics · Generated by Claude Code · /* REPORT_TIME */</footer>

<script>
/* ══════════════════════════════════════════════
   DATA — replace these with real query results
══════════════════════════════════════════════ */

const TRAFFIC = /* TRAFFIC_JSON */;
// e.g. [{ minute:"2024-01-01 12:00", request_count:42, server_errors:1, client_errors:2, avg_latency_ms:145 }, ...]

const WIN_RATE = /* WIN_RATE_JSON */;
// e.g. [{ dino_type:"Agile", total_games:50, wins:38, win_rate_pct:76.0, avg_score:320, avg_speed:1.8 }, ...]

const COINS = /* COINS_JSON */;
// e.g. [{ won:true, games:38, avg_coins:4.2, min_coins:1, max_coins:9 }, { won:false, games:12, avg_coins:1.1, min_coins:0, max_coins:3 }]

const REUSE = /* REUSE_JSON */;
// e.g. [{ dino_name:"Rex", dino_type:"Tank", total_starts:15, reuse_starts:11, fresh_starts:4 }, ...]

const HABITAT = /* HABITAT_JSON */;
// e.g. [{ habitat:"forest", diet:"herbivore", dino_type:"Agile", occurrences:8 }, ...]

/* ══════════════════════════════════════════════
   FLOATING DINO BACKGROUND
══════════════════════════════════════════════ */
const DINOS = ['🦕','🦖','🥚','🌿','🏔️','🌋','⚡','🦴','🍖','💫'];
const bg = document.getElementById('dinoBg');
for(let i=0;i<22;i++){
  const s = document.createElement('span');
  s.textContent = DINOS[Math.floor(Math.random()*DINOS.length)];
  s.style.left = Math.random()*100+'%';
  s.style.animationDuration = (8+Math.random()*14)+'s';
  s.style.animationDelay = (Math.random()*12)+'s';
  s.style.fontSize = (1.5+Math.random()*2.5)+'rem';
  bg.appendChild(s);
}

/* ══════════════════════════════════════════════
   CONFETTI BURST
══════════════════════════════════════════════ */
const CONFETTI_COLORS = ['#16a34a','#facc15','#f97316','#ef4444','#a855f7','#2563eb','#ec4899'];
const cf = document.getElementById('confetti');
for(let i=0;i<60;i++){
  const p = document.createElement('div');
  p.className = 'confetti-piece';
  p.style.background = CONFETTI_COLORS[Math.floor(Math.random()*CONFETTI_COLORS.length)];
  p.style.left = (Math.random()*300-150)+'px';
  p.style.animationDelay = (Math.random()*1.5)+'s';
  p.style.animationDuration = (2+Math.random()*1.5)+'s';
  p.style.transform = `rotate(${Math.random()*360}deg)`;
  cf.appendChild(p);
}

/* ══════════════════════════════════════════════
   CHART DEFAULTS
══════════════════════════════════════════════ */
Chart.defaults.font.family = "'Nunito', sans-serif";
Chart.defaults.font.weight = '700';

/* ══════════════════════════════════════════════
   TRAFFIC CHART
══════════════════════════════════════════════ */
if(TRAFFIC && TRAFFIC.length){
  const labels = TRAFFIC.map(r=>r.minute.slice(11,16)).reverse();
  const reqs   = TRAFFIC.map(r=>r.request_count).reverse();
  const errs   = TRAFFIC.map(r=>r.server_errors).reverse();
  const lat    = TRAFFIC.map(r=>r.avg_latency_ms).reverse();
  new Chart(document.getElementById('trafficChart'),{
    type:'bar',
    data:{
      labels,
      datasets:[
        { label:'Requests', data:reqs, backgroundColor:'rgba(22,163,74,.7)', borderColor:'#16a34a', borderWidth:2, borderRadius:6, yAxisID:'y' },
        { label:'Server Errors', data:errs, backgroundColor:'rgba(239,68,68,.7)', borderColor:'#ef4444', borderWidth:2, borderRadius:6, yAxisID:'y' },
        { label:'Latency (ms)', data:lat, type:'line', borderColor:'#facc15', backgroundColor:'rgba(250,204,21,.15)', borderWidth:3, pointRadius:4, pointHoverRadius:7, tension:.4, yAxisID:'y1' }
      ]
    },
    options:{
      responsive:true,maintainAspectRatio:false,
      interaction:{mode:'index',intersect:false},
      plugins:{legend:{labels:{color:'#374151',padding:16}},tooltip:{backgroundColor:'#166534',titleColor:'#facc15',bodyColor:'#fff',cornerRadius:10,padding:10}},
      scales:{
        y:{beginAtZero:true,grid:{color:'rgba(0,0,0,.06)'},ticks:{color:'#6b7280'}},
        y1:{position:'right',beginAtZero:true,grid:{display:false},ticks:{color:'#eab308'}}
      },
      animation:{duration:1200,easing:'easeOutBounce'}
    }
  });
}

/* ══════════════════════════════════════════════
   WIN RATE CARDS + CHART
══════════════════════════════════════════════ */
const TYPE_COLORS = { Agile:'#22c55e', Tank:'#3b82f6', Speedy:'#facc15', Balanced:'#a855f7' };
function typeColor(t){ return TYPE_COLORS[t] || '#9ca3af'; }

if(WIN_RATE && WIN_RATE.length){
  const cardsEl = document.getElementById('winRateCards');
  WIN_RATE.forEach((r,i)=>{
    const pct = r.win_rate_pct||0;
    const hot = pct > 70;
    const card = document.createElement('div');
    card.className = 'card stat-bubble';
    card.style.borderColor = typeColor(r.dino_type);
    card.style.animationDelay = (i*0.12)+'s';
    card.innerHTML = `
      <div style="font-size:2.5rem;margin-bottom:.3rem" class="wiggle">${{Agile:'⚡',Tank:'🛡️',Speedy:'💨',Balanced:'⚖️'}[r.dino_type]||'🦕'}</div>
      <div class="value" style="font-size:2.4rem;">${pct}%</div>
      <div class="label">${r.dino_type} Win Rate</div>
      <div class="sub">${r.total_games} games · avg score ${r.avg_score}</div>
      ${hot?'<div class="signal alert">🚨 Needs rebalance</div>':'<div class="signal ok">✅ Balanced</div>'}
    `;
    cardsEl.appendChild(card);
  });

  new Chart(document.getElementById('winRateChart'),{
    type:'radar',
    data:{
      labels:WIN_RATE.map(r=>r.dino_type),
      datasets:[
        { label:'Win Rate %', data:WIN_RATE.map(r=>r.win_rate_pct), backgroundColor:'rgba(22,163,74,.25)', borderColor:'#16a34a', borderWidth:3, pointBackgroundColor:WIN_RATE.map(r=>typeColor(r.dino_type)), pointRadius:6 },
        { label:'Avg Score/10', data:WIN_RATE.map(r=>(r.avg_score/10).toFixed(1)), backgroundColor:'rgba(250,204,21,.2)', borderColor:'#facc15', borderWidth:2, pointBackgroundColor:'#facc15', pointRadius:5 }
      ]
    },
    options:{
      responsive:true,maintainAspectRatio:false,
      plugins:{legend:{labels:{color:'#374151'}},tooltip:{backgroundColor:'#166534',titleColor:'#facc15',bodyColor:'#fff',cornerRadius:10}},
      scales:{r:{beginAtZero:true,max:100,grid:{color:'rgba(0,0,0,.08)'},pointLabels:{color:'#374151',font:{size:14,weight:'bold'}},ticks:{backdropColor:'transparent',color:'#9ca3af'}}},
      animation:{duration:1400,easing:'easeOutElastic'}
    }
  });
}

/* ══════════════════════════════════════════════
   COINS CHART + SIGNAL
══════════════════════════════════════════════ */
if(COINS && COINS.length){
  const winRow  = COINS.find(r=>r.won===true||r.won==='true')||{};
  const lossRow = COINS.find(r=>r.won===false||r.won==='false')||{};
  new Chart(document.getElementById('coinsChart'),{
    type:'doughnut',
    data:{
      labels:['Win Avg Coins','Loss Avg Coins'],
      datasets:[{ data:[winRow.avg_coins||0, lossRow.avg_coins||0], backgroundColor:['#22c55e','#ef4444'], borderColor:['#166534','#991b1b'], borderWidth:3, hoverOffset:10 }]
    },
    options:{
      responsive:true,maintainAspectRatio:false,cutout:'65%',
      plugins:{legend:{labels:{color:'#374151',padding:12}},tooltip:{backgroundColor:'#166534',titleColor:'#facc15',bodyColor:'#fff',cornerRadius:10}},
      animation:{animateRotate:true,duration:1200,easing:'easeOutBounce'}
    }
  });
  const winCoins = winRow.avg_coins||0;
  const sig = document.getElementById('coinSignal');
  if(winCoins<=3){
    sig.innerHTML='<div class="signal warn" style="font-size:.95rem;padding:.6rem 1.2rem;">⚠️ Win avg coins ≤ 3 — consider a streak bonus to boost retention</div>';
  } else {
    sig.innerHTML='<div class="signal ok" style="font-size:.95rem;padding:.6rem 1.2rem;">✅ Coin yield looks healthy — players have progression incentive</div>';
  }
}

/* ══════════════════════════════════════════════
   REUSE TABLE
══════════════════════════════════════════════ */
if(REUSE && REUSE.length){
  const tbody = document.getElementById('reuseBody');
  REUSE.forEach((r,i)=>{
    const reuseRate = r.total_starts>0 ? Math.round(r.reuse_starts/r.total_starts*100) : 0;
    const typeCls = `type-${r.dino_type}`;
    const row = document.createElement('tr');
    row.innerHTML = `
      <td><strong>${r.dino_name}</strong></td>
      <td><span class="type-badge ${typeCls}">${r.dino_type||'—'}</span></td>
      <td>${r.total_starts}</td>
      <td><strong style="color:#16a34a;">${r.reuse_starts}</strong></td>
      <td>${r.fresh_starts}</td>
      <td>
        <div style="display:flex;align-items:center;gap:.5rem;">
          <div class="winbar"><div class="winbar-fill" style="width:0%" data-pct="${reuseRate}"></div></div>
          <span style="font-weight:900;color:#374151;">${reuseRate}%</span>
        </div>
      </td>
    `;
    tbody.appendChild(row);
  });
  requestAnimationFrame(()=>{
    document.querySelectorAll('.winbar-fill').forEach(el=>{
      setTimeout(()=>{ el.style.width=el.dataset.pct+'%'; }, 200);
    });
  });
}

/* ══════════════════════════════════════════════
   HABITAT MATRIX
══════════════════════════════════════════════ */
if(HABITAT && HABITAT.length){
  const HABITAT_COLORS={forest:'#166534',desert:'#92400e',swamp:'#065f46',beach:'#0e7490'};
  const DIET_COLORS={herbivore:'#16a34a',carnivore:'#dc2626',omnivore:'#d97706'};
  const matrix = document.getElementById('habitatMatrix');
  const grouped={};
  HABITAT.forEach(r=>{
    const key=`${r.habitat}|${r.diet}`;
    if(!grouped[key]) grouped[key]={habitat:r.habitat,diet:r.diet,types:[]};
    grouped[key].types.push({type:r.dino_type,n:r.occurrences});
  });
  const habitats=[...new Set(HABITAT.map(r=>r.habitat))];
  const diets=[...new Set(HABITAT.map(r=>r.diet))];
  const grid = document.createElement('div');
  grid.style.cssText='display:grid;gap:.75rem;';
  habitats.forEach(h=>{
    const row=document.createElement('div');
    row.className='matrix-row';
    const hLabel=document.createElement('div');
    hLabel.style.cssText=`font-weight:900;font-size:.9rem;min-width:80px;color:${HABITAT_COLORS[h]||'#374151'};`;
    hLabel.textContent='🗺️ '+h;
    row.appendChild(hLabel);
    diets.forEach(d=>{
      const key=`${h}|${d}`;
      const entry=grouped[key];
      if(!entry) return;
      const allSameType = new Set(entry.types.map(t=>t.type)).size===1;
      const cell=document.createElement('div');
      cell.className='matrix-cell';
      const bg=DIET_COLORS[d]||'#6b7280';
      cell.style.cssText=`background:${bg}18;color:${bg};border-color:${bg};`;
      const typeSummary=entry.types.map(t=>`${t.type}(${t.n})`).join(', ');
      cell.innerHTML=`<span>${d}</span> → <strong>${typeSummary}</strong>${allSameType?' 🎯':''}`;
      cell.title=allSameType?'Deterministic! Great for type preview UI':'Multiple outcomes';
      row.appendChild(cell);
    });
    grid.appendChild(row);
  });
  matrix.appendChild(grid);
  const deterministicCombos=Object.values(grouped).filter(g=>new Set(g.types.map(t=>t.type)).size===1);
  if(deterministicCombos.length>0){
    const sig=document.createElement('div');
    sig.className='signal ok';
    sig.style.marginTop='1rem';
    sig.innerHTML=`🎯 ${deterministicCombos.length} habitat+diet combo(s) are 100% deterministic — show type preview before confirm!`;
    matrix.appendChild(sig);
  }
}

/* ══════════════════════════════════════════════
   ANIMATED NUMBER COUNTERS
══════════════════════════════════════════════ */
function animateCount(el, target, suffix=''){
  const duration=1200, start=performance.now(), from=0;
  function step(now){
    const t=Math.min((now-start)/duration,1);
    const ease=1-Math.pow(1-t,3);
    el.textContent=Math.round(from+(target-from)*ease)+suffix;
    if(t<1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}
document.querySelectorAll('.value[data-count]').forEach(el=>{
  animateCount(el, parseFloat(el.dataset.count), el.dataset.suffix||'');
});
</script>
</body>
</html>
```

---

#### Data injection rules

When writing the file, replace each placeholder with a JS literal constructed from real query data:

| Placeholder | Replace with |
|---|---|
| `/* REPORT_TIME */` | ISO-8601 string from the current timestamp |
| `/* TOTAL_REQUESTS */` | sum of `request_count` across all traffic rows |
| `/* TOTAL_ERRORS */` | sum of `server_errors` across all traffic rows |
| `/* AVG_LATENCY */` | average of `avg_latency_ms` across all traffic rows, rounded |
| `/* TRAFFIC_JSON */` | JSON array from Step 2.2 results |
| `/* WIN_RATE_JSON */` | JSON array from Step 3.1 results |
| `/* COINS_JSON */` | JSON array from Step 3.2 results |
| `/* REUSE_JSON */` | JSON array from Step 3.3 results |
| `/* HABITAT_JSON */` | JSON array from Step 3.4 results |
| `/* WIN_AVG_COINS */` | avg_coins where won=true, 1 decimal |
| `/* WIN_GAMES */` | games count where won=true |
| `/* LOSS_AVG_COINS */` | avg_coins where won=false, 1 decimal |
| `/* LOSS_GAMES */` | games count where won=false |

If any query returned no data, substitute an empty array `[]` for that dataset — the JS gracefully skips empty sections.

---

## Edge Cases

- **Dataset/table not found after sink creation**: Logs take 1–5 minutes to appear. Retry Phase 2
  after waiting.
- **BigQuery `execute_sql` returns empty results**: No traffic in the last hour, or the sink was
  just created. Try extending the `INTERVAL` to `INTERVAL 24 HOUR`.
- **Sink already exists but BigQuery has no data**: Verify the `writerIdentity` has `bigquery.dataEditor`
  on the dataset by checking IAM (run `scripts/check_sink.sh` for diagnostics).
- **MCP server disabled**: Enable `google-cloud-logging` and `google-bigquery` in `mcp_config.json`
  and restart the agent before retrying.
- **Phase 3 `Unrecognized name: jsonPayload`**: There is no `jsonPayload` column. The backend uses
  `print(json.dumps({...}))`, so events are plain JSON strings in `textPayload`. Use
  `JSON_VALUE(textPayload, '$.field')` for all field access.
- **Phase 3 boolean fields**: `won` and `is_reuse` are JSON string values, not native BOOL.
  Compare with `= 'true'` / `= 'false'`, not `= TRUE`.
- **Phase 3 DINO_CREATED returns empty**: Events only fire on new dino generation. Always use the
  7-day wildcard query from Step 3.4 to aggregate across multiple daily tables.
- **Phase 3 numeric cast errors**: Extract with `JSON_VALUE` first, then cast:
  `SAFE_CAST(JSON_VALUE(textPayload, '$.score') AS FLOAT64)`.
