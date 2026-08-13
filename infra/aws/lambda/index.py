"""Starts the GiTF instance when called with the right token.

Exposed via a Lambda function URL; the WAKE_TOKEN check is the entire auth,
so treat the full URL (with token) as a secret.
"""

import json
import os

import boto3
from botocore.exceptions import ClientError


def handler(event, _context):
    params = event.get("queryStringParameters") or {}
    if params.get("token") != os.environ["WAKE_TOKEN"]:
        return {"statusCode": 403, "body": "forbidden"}

    instance_id = os.environ["INSTANCE_ID"]

    # start_instances is idempotent (a no-op on running instances) and its
    # response already carries the state — no describe round-trip needed.
    try:
        resp = boto3.client("ec2").start_instances(InstanceIds=[instance_id])
        state = resp["StartingInstances"][0]["CurrentState"]["Name"]
        status = 200
    except ClientError as err:
        # e.g. IncompatibleInstanceState while the instance is still stopping.
        state = err.response.get("Error", {}).get("Code", "error")
        status = 409

    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"instance": instance_id, "state": state}),
    }
