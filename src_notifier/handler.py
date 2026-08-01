import json
import os
import boto3
import urllib.request
import urllib.parse

secrets = boto3.client("secretsmanager", region_name="us-east-1")

def lambda_handler(event, context):
    secret_name = os.environ["SECRET_NAME"]
    data = json.loads(secrets.get_secret_value(SecretId=secret_name)["SecretString"])
    token = data["telegram_token"]
    chat_id = data["chat_id"]
    for record in event.get("Records", []):
        message = record["Sns"]["Message"]
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        req = urllib.parse.urlencode({"chat_id": chat_id, "text": message}).encode()
        with urllib.request.urlopen(url, data=req) as resp:
            json.loads(resp.read().decode())
    return {"statusCode": 200}
