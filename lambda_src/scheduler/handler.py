import json, os, boto3
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from boto3.dynamodb.conditions import Attr

ddb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
jobs = ddb.Table(os.environ["JOBS_TABLE"])
grid = ddb.Table(os.environ["GRID_TABLE"])
QUEUE_URL = os.environ["QUEUE_URL"]

IST = timezone(timedelta(hours=5, minutes=30))
# Fallback profile (gCO2/kWh) used ONLY if DynamoDB lacks actual/forecast data for an hour
PROFILE = [760, 760, 755, 750, 745, 740, 720, 690, 640, 580, 530, 500,
           490, 495, 520, 570, 640, 720, 790, 800, 790, 780, 770, 765]
CLEAN_THRESHOLD = 560
MARGIN_MIN = 5


def profile_at(dt):
    return PROFILE[dt.astimezone(IST).hour]


def hour_key(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:00Z")


def refresh_grid(now):
    """Backfill missing future hours without overwriting live/forecast data from Ingest Lambda."""
    for i in range(24):
        t = now + timedelta(hours=i)
        key = hour_key(t)
        fallback_val = Decimal(str(profile_at(t)))
        
        # update_item with if_not_exists ensures ingest Lambda data is preserved
        grid.update_item(
            Key={"hour": key},
            UpdateExpression="SET intensity = if_not_exists(intensity, :f), #s = if_not_exists(#s, :src)",
            ExpressionAttributeNames={"#s": "source"},
            ExpressionAttributeValues={
                ":f": fallback_val,
                ":src": "fallback_profile"
            }
        )


def get_hour_intensity(dt):
    """Fetch intensity for a specific hour from DynamoDB, falling back to PROFILE if missing."""
    item = grid.get_item(Key={"hour": hour_key(dt)}).get("Item")
    if item and "intensity" in item:
        return float(item["intensity"])
    return float(profile_at(dt))


def current_intensity(now):
    """Check for manual OVERRIDE first, then read current hour from DynamoDB."""
    override = grid.get_item(Key={"hour": "OVERRIDE"}).get("Item")
    if override and "intensity" in override:
        return float(override["intensity"])
    return get_hour_intensity(now)


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    refresh_grid(now)
    current = current_intensity(now)
    pending = jobs.scan(FilterExpression=Attr("status").eq("PENDING"))["Items"]
    released = 0

    for job in pending:
        deadline = datetime.fromisoformat(job["deadline"])
        latest_start = deadline - timedelta(minutes=int(job["duration_minutes"]) + MARGIN_MIN)

        if now >= latest_start:
            reason = "deadline"
        else:
            hours_left = min(24, int((latest_start - now).total_seconds() // 3600))
            
            # Read real values/forecasts from DynamoDB for future decision windows
            future_intensities = [
                get_hour_intensity(now + timedelta(hours=h))
                for h in range(hours_left + 1)
            ]
            best_future = min(future_intensities) if future_intensities else current

            if current <= CLEAN_THRESHOLD:
                reason = "clean grid"
            elif current <= best_future * 1.05:
                reason = "best available window"
            else:
                continue  # hold: a cleaner window is coming before the deadline

        try:
            jobs.update_item(
                Key={"job_id": job["job_id"]},
                UpdateExpression="SET #s=:q, scheduled_at=:t, release_reason=:r, release_intensity=:i",
                ConditionExpression="#s = :p",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":q": "QUEUED", ":p": "PENDING", ":t": now.isoformat(),
                    ":r": reason, ":i": Decimal(str(current)),
                },
            )
        except ddb.meta.client.exceptions.ConditionalCheckFailedException:
            continue
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"job_id": job["job_id"]}))
        released += 1

    return {"pending": len(pending), "released": released, "intensity": current}