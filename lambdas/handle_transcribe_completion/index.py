import boto3
import json
import os

sfn = boto3.client("stepfunctions")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    detail = event["detail"]
    job_name = detail["TranscriptionJobName"]

    item = table.get_item(Key={"job_name": job_name}).get("Item")
    task_token = item["task_token"]

    if detail["TranscriptionJobStatus"] == "COMPLETED":
        sfn.send_task_success(taskToken=task_token, output=json.dumps(detail))
    else:
        sfn.send_task_failure(
            taskToken=task_token,
            error="TranscribeJobFailed",
            cause=json.dumps(detail)
        )

    table.delete_item(Key={"job_name": job_name})