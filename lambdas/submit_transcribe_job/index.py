import boto3
import os
import re

transcribe = boto3.client("transcribe")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    task_token = event["TaskToken"]
    input_key = event["input_key"]
    language_code = event["language_code"]
    video_id = event["video_id"]

    # Build a readable job name from the video's own filename, plus
    # video_id to guarantee uniqueness (Transcribe job names must be
    # unique account-wide, forever - a plain filename would collide
    # on any re-test using the same name). Transcribe only allows
    # 0-9a-zA-Z._- in job names, so strip anything else.
    base_name = os.path.splitext(os.path.basename(input_key))[0]
    base_name = re.sub(r"[^0-9a-zA-Z._-]", "_", base_name)[:100]
    job_name = f"{base_name}-{video_id}"

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