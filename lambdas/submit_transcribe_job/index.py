import boto3
import os
import uuid

transcribe = boto3.client("transcribe")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    task_token = event["TaskToken"]
    input_key = event["input_key"]
    language_code = event["language_code"]

    job_name = f"transcribe-{uuid.uuid4()}"

    transcribe.start_transcription_job(
        TranscriptionJobName=job_name,
        Media={
            "MediaFileUri": f"s3://{os.environ['INPUT_BUCKET']}/{input_key}"
        },
        MediaFormat="mp4",
        LanguageCode=language_code,
        OutputBucketName=os.environ["OUTPUT_BUCKET"],
        OutputKey=f"transcripts/{job_name}.json"
    )

    table.put_item(Item={"job_name": job_name, "task_token": task_token})