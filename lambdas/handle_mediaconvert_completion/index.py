import boto3
import json
import os

sfn = boto3.client("stepfunctions")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    detail = event["detail"]
    job_id = detail["jobId"]

    item = table.get_item(Key={"job_id": job_id}).get("Item")
    task_token = item["task_token"]

    if detail["status"] == "COMPLETE":
        sfn.send_task_success(taskToken=task_token, output=json.dumps(detail))
    else:
        sfn.send_task_failure(
            taskToken=task_token,
            error="MediaConvertJobFailed",
            cause=json.dumps(detail)
        )

    table.delete_item(Key={"job_id": job_id})