import os
import random
import json
from datetime import datetime, timedelta

PROJECT_ID = "io26-keynote-demo-staging"
DATASET_ID = "dinoquest_logs"

create_tables_sql = f"""
CREATE SCHEMA IF NOT EXISTS `{PROJECT_ID}.{DATASET_ID}`;

CREATE TABLE IF NOT EXISTS `{PROJECT_ID}.{DATASET_ID}.run_googleapis_com_stdout` (
    timestamp TIMESTAMP,
    textPayload STRING
) PARTITION BY DATE(timestamp);

CREATE TABLE IF NOT EXISTS `{PROJECT_ID}.{DATASET_ID}.run_googleapis_com_requests` (
    timestamp TIMESTAMP,
    httpRequest STRUCT<status INT64, latency FLOAT64, requestUrl STRING>
) PARTITION BY DATE(timestamp);

CREATE TABLE IF NOT EXISTS `{PROJECT_ID}.{DATASET_ID}.run_googleapis_com_stderr` (
    timestamp TIMESTAMP,
    severity STRING,
    textPayload STRING
) PARTITION BY DATE(timestamp);
"""

now = datetime.utcnow()
stdout_values = []
requests_values = []
stderr_values = []

dino_types = ["Agile", "Tank", "Speedy", "Balanced"]
habitats = ["forest", "volcano", "desert", "ocean"]
diets = ["herbivore", "carnivore", "omnivore"]
dino_names = [
    "Rex", "Swift", "Spike", "Chomper", "Littlefoot", "Petrie", "Cera", "Ducky", "Flier", "Sharptooth",
    "Thorn", "Bramble", "Ember", "Drake", "Fang", "Talon", "Boulder", "Ridge", "Onyx", "Flint",
    "Ash", "Echo", "Apollo", "Nova", "Rocky"
]

for i in range(4000):
    ts = now - timedelta(minutes=random.randint(1, 1400))
    ts_str = ts.strftime("%Y-%m-%d %H:%M:%S UTC")
    
    rand_val = random.random()
    if rand_val < 0.6:  # 60% game events
        event_type = random.choice(["GAME_START", "GAME_END", "DINO_CREATED"])
        if event_type == "GAME_END":
            dino_type = random.choice(dino_types)
            won = "true" if random.random() < 0.55 else "false"
            score = random.randint(100, 500)
            speed = round(random.uniform(0.5, 2.5), 2)
            coins = random.randint(3, 10) if won == "true" else random.randint(0, 3)
            payload = json.dumps({
                "event": "GAME_END", "dino_type": dino_type, "won": won,
                "score": str(score), "speed": str(speed), "coins": str(coins)
            })
        elif event_type == "GAME_START":
            dino_name = random.choice(dino_names)
            dino_type = random.choice(dino_types)
            is_reuse = "true" if random.random() < 0.4 else "false"
            payload = json.dumps({
                "event": "GAME_START", "dino_name": dino_name,
                "dino_type": dino_type, "is_reuse": is_reuse
            })
        else: # DINO_CREATED
            habitat = random.choice(habitats)
            diet = random.choice(diets)
            generated_type = random.choice(dino_types)
            payload = json.dumps({
                "event": "DINO_CREATED", "habitat": habitat,
                "diet": diet, "generated_type": generated_type
            })
            
        stdout_values.append(f"('{ts_str}', '{payload}')")
        
    elif rand_val < 0.9:  # 30% HTTP requests
        status = random.choice([200, 200, 200, 200, 400, 500, 404])
        latency = round(random.uniform(0.05, 1.5), 3)
        if status == 500:
            latency = round(random.uniform(2.0, 5.0), 3)
        requests_values.append(f"('{ts_str}', STRUCT({status}, {latency}, 'https://dinoquest.run.app/api/generate'))")
        
    else:  # 10% errors
        severity = random.choice(["ERROR", "CRITICAL"])
        errors = [
            "ValueError: GEMINI_API_KEY is not set in backend/.env!",
            "ConnectionError: Timeout communicating with Spanner",
            "OutOfMemory: Process exceeded memory limit",
            "KeyError: 'dino_type' not found in response payload"
        ]
        msg = random.choice(errors)
        stderr_values.append(f"('{ts_str}', '{severity}', '{msg}')")

with open("setup/create_tables.sql", "w") as f:
    f.write(create_tables_sql)

print("Creating BigQuery tables...")
os.system("bq query --nouse_legacy_sql < setup/create_tables.sql")

def batch_insert(table, columns, values):
    if not values: return
    batch_size = 200
    for i in range(0, len(values), batch_size):
        batch = values[i:i+batch_size]
        sql = f"INSERT INTO `{PROJECT_ID}.{DATASET_ID}.{table}` ({columns}) VALUES\n" + ",\n".join(batch) + ";"
        with open("setup/insert_batch.sql", "w") as f:
            f.write(sql)
        os.system("bq query --nouse_legacy_sql < setup/insert_batch.sql > /dev/null")

print(f"Seeding {len(stdout_values)} stdout records...")
batch_insert("run_googleapis_com_stdout", "timestamp, textPayload", stdout_values)

print(f"Seeding {len(requests_values)} requests records...")
batch_insert("run_googleapis_com_requests", "timestamp, httpRequest", requests_values)

print(f"Seeding {len(stderr_values)} stderr records...")
batch_insert("run_googleapis_com_stderr", "timestamp, severity, textPayload", stderr_values)

# Cleanup temp files
try:
    os.remove("setup/create_tables.sql")
    os.remove("setup/insert_batch.sql")
except:
    pass

print("✅ Data seeding complete!")
