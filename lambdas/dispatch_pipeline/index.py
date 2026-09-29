import boto3
import hashlib
import json
import os
import time
import urllib.parse
import uuid

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
sfn = boto3.client("stepfunctions")

TABLE = dynamodb.Table(os.environ["COURSE_METADATA_TABLE"])
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
DEFAULT_LANGUAGE_CODE = os.environ.get("DEFAULT_LANGUAGE_CODE", "en-US")

def handler(event, context):
    for s3_record in event["Records"]:
        process_upload(s3_record)

def process_upload(s3_record):
    bucket = s3_record["s3"]["bucket"]["name"]

    # S3 event keys are URL-encoded (spaces become '+', etc.) - decode
    # before treating this as a real object key.
    raw_key = s3_record["s3"]["object"]["key"]
    input_key = urllib.parse.unquote_plus(raw_key)

    # Deterministic execution name from bucket+key, so a duplicate S3
    # event (SQS delivers at-least-once) doesn't start a second
    # execution for the same upload.
    execution_name = hashlib.sha256(f"{bucket}/{input_key}".encode()).hexdigest()[:80]

    # Language is supplied as S3 object metadata at upload time
    # (language-code) until Step 9's frontend exists to collect it
    # properly. Falls back to a default so a quick manual test upload
    # without that metadata set doesn't hard-fail.
    head = s3.head_object(Bucket=bucket, Key=input_key)
    language_code = head.get("Metadata", {}).get("language-code", DEFAULT_LANGUAGE_CODE)

    video_id = str(uuid.uuid4())

    try:
        sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=execution_name,
            input=json.dumps({
                "video_id": video_id,
                "input_key": input_key,
                "language_code": language_code
            })
        )
    except sfn.exceptions.ExecutionAlreadyExists:
        # Same upload event delivered more than once - the first
        # delivery already started this execution, nothing more to do.
        print(f"Execution {execution_name} already exists - skipping duplicate")
        return

    TABLE.put_item(Item={
        "video_id": video_id,
        "input_key": input_key,
        "language_code": language_code,
        "status": "PROCESSING",
        "created_at": int(time.time())
    })