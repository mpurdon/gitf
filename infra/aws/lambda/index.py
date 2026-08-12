"""Starts the GiTF instance when called with the right token.

Exposed via a Lambda function URL; the WAKE_TOKEN check is the entire auth,
so treat the full URL (with token) as a secret.
"""

import json
import os

import boto3


def handler(event, _context):
    params = event.get("queryStringParameters") or {}
    if params.get("token") != os.environ["WAKE_TOKEN"]:
        return {"statusCode": 403, "body": "forbidden"}

    instance_id = os.environ["INSTANCE_ID"]
    ec2 = boto3.client("ec2")

    state = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0][
        "Instances"
    ][0]["State"]["Name"]

    if state in ("stopped", "stopping"):
        ec2.start_instances(InstanceIds=[instance_id])
        message = "starting"
    else:
        message = state

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"instance": instance_id, "state": message}),
    }
