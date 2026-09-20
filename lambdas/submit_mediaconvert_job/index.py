import boto3
import os

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    task_token = event["TaskToken"]
    input_key = event["input_key"]

    mc_generic = boto3.client("mediaconvert")
    endpoint = mc_generic.describe_endpoints()["Endpoints"][0]["Url"]
    mc = boto3.client("mediaconvert", endpoint_url=endpoint)

    response = mc.create_job(
        Role=os.environ["MEDIACONVERT_ROLE_ARN"],
        Settings={
                        "Inputs": [{
                "FileInput": f"s3://{os.environ['INPUT_BUCKET']}/{input_key}",
                "AudioSelectors": {
                    "Audio Selector 1": {"DefaultSelection": "DEFAULT"}
                }
            }],
            "OutputGroups": [{
                "OutputGroupSettings": {
                    "Type": "FILE_GROUP_SETTINGS",
                    "FileGroupSettings": {
                        "Destination": f"s3://{os.environ['OUTPUT_BUCKET']}/transcoded/"
                    }
                },
                "Outputs": [{
                    "ContainerSettings": {"Container": "MP4"},
                    "VideoDescription": {
                        "Width": 1920,
                        "Height": 1080,
                        "CodecSettings": {
                            "Codec": "H_264",
                            "H264Settings": {
                                "RateControlMode": "QVBR",
                                "QvbrSettings": {"QvbrQualityLevel": 7},
                                "MaxBitrate": 5000000
                            }
                        }
                    },
                    "AudioDescriptions": [{
                        "AudioSourceName": "Audio Selector 1",
                        "CodecSettings": {
                            "Codec": "AAC",
                            "AacSettings": {
                                "Bitrate": 128000,
                                "CodingMode": "CODING_MODE_2_0",
                                "SampleRate": 48000
                            }
                        }
                    }]
                }]
            }]
        }
    )

    job_id = response["Job"]["Id"]
    table.put_item(Item={"job_id": job_id, "task_token": task_token})