import json, os, urllib.parse, urllib.request
from datetime import datetime, timezone
from decimal import Decimal
import boto3

grid = boto3.resource("dynamodb").Table(os.environ["GRID_TABLE"])
ZONE = os.environ["EM_ZONE"]
KEY = os.environ["EM_API_KEY"]
BASE = "https://api.electricitymaps.com/v3/carbon-intensity/"


def fetch(endpoint):
    url = BASE + endpoint + "?" + urllib.parse.urlencode({"zone": ZONE})
    req = urllib.request.Request(url, headers={"auth-token": KEY})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def hour_key(iso):
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:00Z")


def lambda_handler(event, context):
    now_key = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:00Z")
    result = {}

    latest = fetch("latest")
    ci = latest.get("carbonIntensity")
    if ci is not None:
        grid.update_item(
            Key={"hour": hour_key(latest["datetime"])},
            UpdateExpression="SET actual=:a, intensity=:a, #s=:l, is_estimated=:e",
            ExpressionAttributeNames={"#s": "source"},
            ExpressionAttributeValues={":a": Decimal(str(ci)), ":l": "live",
                                       ":e": bool(latest.get("isEstimated"))},
        )
        result["latest"] = ci

    try:
        written = 0
        for p in fetch("forecast").get("forecast", []):
            key = hour_key(p["datetime"])
            if key <= now_key or p.get("carbonIntensity") is None:
                continue  # only future hours, so the forecast stays frozen once the hour starts
            grid.update_item(
                Key={"hour": key},
                UpdateExpression="SET forecast=:f, intensity=if_not_exists(actual, :f), #s=if_not_exists(#s, :src)",
                ExpressionAttributeNames={"#s": "source"},
                ExpressionAttributeValues={":f": Decimal(str(p["carbonIntensity"])), ":src": "forecast"},
            )
            written += 1
        result["forecast_hours"] = written
    except Exception as e:
        print("forecast fetch failed:", e)  # scheduler falls back to the profile
        result["forecast_error"] = str(e)

    return result