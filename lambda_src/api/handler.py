import base64
import json, os, uuid, boto3
from datetime import datetime, timedelta, timezone
from decimal import Decimal

ddb = boto3.resource("dynamodb")
jobs = ddb.Table(os.environ["JOBS_TABLE"])
grid = ddb.Table(os.environ["GRID_TABLE"])
DEFAULT_INTENSITY = 700

def get_body(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    return json.loads(raw)


def resp(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=lambda o: float(o) if isinstance(o, Decimal) else str(o)),
    }


def current_intensity():
    item = grid.get_item(Key={"hour": "OVERRIDE"}).get("Item")
    if item:
        return float(item["intensity"])
    hour = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:00Z")
    item = grid.get_item(Key={"hour": hour}).get("Item")
    return float(item["intensity"]) if item else DEFAULT_INTENSITY


def lambda_handler(event, context):
    method = event["requestContext"]["http"]["method"]
    path = event["rawPath"]

    if method == "POST" and path == "/jobs":
        body = json.loads(event.get("body") or "{}")
        now = datetime.now(timezone.utc)
        job = {
            "job_id": uuid.uuid4().hex[:8],
            "workload": body.get("workload", "cpu-burn"),
            "submitted_at": now.isoformat(),
            "deadline": (now + timedelta(minutes=int(body.get("deadline_minutes", 240)))).isoformat(),
            "duration_minutes": int(body.get("duration_minutes", 5)),
            "status": "PENDING",
            "baseline_intensity": Decimal(str(current_intensity())),
        }
        jobs.put_item(Item=job)
        return resp(201, job)

    if method == "GET" and path == "/jobs":
        items = jobs.scan()["Items"]
        items.sort(key=lambda j: j["submitted_at"], reverse=True)
        return resp(200, items)

    if method == "GET" and path == "/grid":
        items = grid.scan()["Items"]
        items.sort(key=lambda g: g["hour"])
        return resp(200, items)

    if method == "POST" and path == "/override":
        value = json.loads(event.get("body") or "{}").get("intensity")
        if value is None:
            grid.delete_item(Key={"hour": "OVERRIDE"})
        else:
            grid.put_item(Item={"hour": "OVERRIDE", "intensity": Decimal(str(value))})
        return resp(200, {"override": value})

    return resp(404, {"error": "not found"})