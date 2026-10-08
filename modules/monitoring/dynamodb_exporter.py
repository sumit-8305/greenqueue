import logging
import os
import threading
import time
from datetime import datetime, timezone

import boto3
from prometheus_client import Counter, Gauge, start_http_server


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("greenqueue-exporter")

REGION = os.environ["AWS_DEFAULT_REGION"]
JOBS_TABLE = os.environ["JOBS_TABLE"]
GRID_TABLE = os.environ["GRID_TABLE"]
QUEUE_URL = os.environ["QUEUE_URL"]
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "30"))

ddb = boto3.resource("dynamodb", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
jobs_table = ddb.Table(JOBS_TABLE)
grid_table = ddb.Table(GRID_TABLE)

job_count = Gauge("greenqueue_jobs", "Current GreenQueue jobs by status", ["status"])
energy_kwh = Gauge(
    "greenqueue_estimated_energy_kwh",
    "Estimated energy for completed jobs, summed from DynamoDB",
)
emissions_gco2 = Gauge(
    "greenqueue_estimated_emissions_gco2",
    "Estimated emissions for completed jobs, summed from DynamoDB",
    ["basis"],
)
grid_intensity = Gauge(
    "greenqueue_grid_carbon_intensity_gco2_per_kwh",
    "Current configured grid intensity (demo profile or override)",
)
queue_messages = Gauge(
    "greenqueue_sqs_messages",
    "Approximate SQS message count",
    ["state"],
)
last_refresh = Gauge(
    "greenqueue_exporter_last_refresh_timestamp_seconds",
    "Unix timestamp of the last successful AWS data refresh",
)
refresh_errors = Counter(
    "greenqueue_exporter_refresh_errors_total",
    "Number of failed AWS data refresh attempts",
)

STATUSES = ("PENDING", "QUEUED", "RUNNING", "DONE")


def scan_all_jobs():
    items = []
    scan_args = {}
    while True:
        response = jobs_table.scan(**scan_args)
        items.extend(response.get("Items", []))
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            return items
        scan_args = {"ExclusiveStartKey": last_key}


def read_current_intensity():
    override = grid_table.get_item(Key={"hour": "OVERRIDE"}).get("Item")
    if override:
        return float(override["intensity"])

    current_hour = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:00Z")
    item = grid_table.get_item(Key={"hour": current_hour}).get("Item")
    return float(item["intensity"]) if item else float("nan")


def refresh_metrics():
    items = scan_all_jobs()
    counts = dict.fromkeys(STATUSES, 0)
    total_kwh = 0.0
    actual_gco2 = 0.0
    baseline_gco2 = 0.0

    for item in items:
        status = item.get("status")
        if status in counts:
            counts[status] += 1
        if status == "DONE":
            total_kwh += float(item.get("kwh", 0))
            actual_gco2 += float(item.get("actual_gco2", 0))
            baseline_gco2 += float(item.get("baseline_gco2", 0))

    for status, count in counts.items():
        job_count.labels(status=status).set(count)

    energy_kwh.set(total_kwh)
    emissions_gco2.labels(basis="completion_intensity_estimate").set(actual_gco2)
    emissions_gco2.labels(basis="submission_baseline").set(baseline_gco2)
    grid_intensity.set(read_current_intensity())

    attributes = sqs.get_queue_attributes(
        QueueUrl=QUEUE_URL,
        AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
    )["Attributes"]
    queue_messages.labels(state="visible").set(
        int(attributes.get("ApproximateNumberOfMessages", 0))
    )
    queue_messages.labels(state="inflight").set(
        int(attributes.get("ApproximateNumberOfMessagesNotVisible", 0))
    )
    last_refresh.set(time.time())


def refresh_loop():
    while True:
        try:
            refresh_metrics()
        except Exception:
            refresh_errors.inc()
            logger.exception("Failed to refresh metrics from AWS")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    start_http_server(9108, addr="0.0.0.0")
    threading.Thread(target=refresh_loop, daemon=True).start()
    logger.info("Serving Prometheus metrics on port 9108")
    threading.Event().wait()