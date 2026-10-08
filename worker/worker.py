import json, os, subprocess, time, urllib.request
from datetime import datetime, timezone
from decimal import Decimal
import boto3, psutil

REGION = os.environ["AWS_DEFAULT_REGION"]
ddb = boto3.resource("dynamodb", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
asg = boto3.client("autoscaling", region_name=REGION)
jobs = ddb.Table(os.environ["JOBS_TABLE"])
grid = ddb.Table(os.environ["GRID_TABLE"])
QUEUE_URL = os.environ["QUEUE_URL"]
ASG_NAME = os.environ["ASG_NAME"]

# Power model (Cloud Carbon Footprint-style averages for AWS): estimate, not a measurement
VCPUS = psutil.cpu_count()
MIN_W, MAX_W = 0.74 * VCPUS, 3.5 * VCPUS


def imds(path):
    tok = urllib.request.urlopen(urllib.request.Request(
        "http://169.254.169.254/latest/api/token", method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})).read().decode()
    return urllib.request.urlopen(urllib.request.Request(
        "http://169.254.169.254/latest/meta-data/" + path,
        headers={"X-aws-ec2-metadata-token": tok})).read().decode()


IID = imds("instance-id")


def protect(flag):
    try:
        asg.set_instance_protection(InstanceIds=[IID], AutoScalingGroupName=ASG_NAME,
                                    ProtectedFromScaleIn=flag)
    except Exception as e:
        print("protect failed:", e)


def current_intensity():
    item = grid.get_item(Key={"hour": "OVERRIDE"}).get("Item")
    if not item:
        key = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:00Z")
        item = grid.get_item(Key={"hour": key}).get("Item")
    return float(item["intensity"]) if item else 700.0


def run_job(job):
    seconds = float(job["duration_minutes"]) * 60
    code = f"import time\nend=time.time()+{seconds}\nwhile time.time()<end: pass"
    start = time.time()
    p = subprocess.Popen(["docker", "run", "--rm", "python:3.12-alpine", "python", "-c", code])
    samples = []
    psutil.cpu_percent(None)
    while p.poll() is None:
        time.sleep(5)
        samples.append(psutil.cpu_percent(None))
    if p.returncode != 0:
        raise RuntimeError("workload failed")
    avg_cpu = sum(samples) / len(samples) if samples else 0.0
    hours = (time.time() - start) / 3600
    kwh = (MIN_W + (MAX_W - MIN_W) * avg_cpu / 100) * hours / 1000
    return avg_cpu, kwh


def handle(job_id):
    job = jobs.get_item(Key={"job_id": job_id}).get("Item")
    if not job or job.get("status") not in ("QUEUED", "RUNNING"):
        return True  # missing or already finished: just drop the message
    jobs.update_item(Key={"job_id": job_id},
                     UpdateExpression="SET #s=:r, started_at=:t, worker=:w",
                     ExpressionAttributeNames={"#s": "status"},
                     ExpressionAttributeValues={":r": "RUNNING", ":t": datetime.now(timezone.utc).isoformat(), ":w": IID})
    avg_cpu, kwh = run_job(job)
    actual = kwh * current_intensity()
    baseline = kwh * float(job["baseline_intensity"])
    jobs.update_item(Key={"job_id": job_id},
                     UpdateExpression="SET #s=:d, finished_at=:t, avg_cpu=:c, kwh=:k, actual_gco2=:a, baseline_gco2=:b",
                     ExpressionAttributeNames={"#s": "status"},
                     ExpressionAttributeValues={":d": "DONE", ":t": datetime.now(timezone.utc).isoformat(),
                                                ":c": Decimal(str(round(avg_cpu, 2))), ":k": Decimal(str(round(kwh, 8))),
                                                ":a": Decimal(str(round(actual, 6))), ":b": Decimal(str(round(baseline, 6)))})
    return True


while True:
    resp = sqs.receive_message(QueueUrl=QUEUE_URL, MaxNumberOfMessages=1, WaitTimeSeconds=20)
    for m in resp.get("Messages", []):
        protect(True)
        try:
            if handle(json.loads(m["Body"])["job_id"]):
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])
        except Exception as e:
            print("job failed:", e)  # message reappears and eventually lands in the DLQ
        finally:
            protect(False)