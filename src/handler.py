import json
import boto3
import os
import uuid
from datetime import datetime, timezone
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

secrets = boto3.client("secretsmanager", region_name="us-east-1")
dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
sns = boto3.client("sns", region_name="us-east-1")
analyzer = SentimentIntensityAnalyzer()


def lambda_handler(event, context):
    secret_name = os.environ["SECRET_NAME"]
    table_name = os.environ["TABLE_NAME"]
    topic_arn = os.environ["TOPIC_ARN"]
    data = json.loads(secrets.get_secret_value(SecretId=secret_name)["SecretString"])
    api_key = data["api_key"]

    # ---- AUTH: reject requests without the correct API key ----
    headers = event.get("headers") or {}
    if headers.get("x-api-key", "") != api_key:
        return {"statusCode": 403, "body": json.dumps({"error": "Forbidden - missing or invalid API key"})}

    # ---- read the ticket text from the POST body ----
    body = event.get("body") or "{}"
    try:
        payload_in = json.loads(body)
    except Exception:
        payload_in = {}
    text = payload_in.get("text", "").strip()
    if not text:
        return {"statusCode": 400, "body": json.dumps({"error": "Missing 'text' in request body"})}

    # ---- INTELLIGENCE: score sentiment in-Lambda with VADER ----
    scores = analyzer.polarity_scores(text)
    compound = scores["compound"]
    if compound <= -0.05:
        sentiment = "NEGATIVE"
    elif compound >= 0.05:
        sentiment = "POSITIVE"
    else:
        sentiment = "NEUTRAL"

    # ---- STORE every ticket in DynamoDB ----
    ticket_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()
    dynamodb.Table(table_name).put_item(Item={
        "ticketId": ticket_id, "timestamp": timestamp,
        "text": text, "sentiment": sentiment, "compound": str(compound)
    })

    # ---- FAN-OUT: publish NEGATIVE tickets to SNS ----
    # SNS then delivers to all three consumers: email, Telegram notifier, archival.
    published = False
    if sentiment == "NEGATIVE":
        alert = f"\u26a0\ufe0f NEGATIVE ticket received:\n\"{text}\"\n(score: {compound})"
        sns.publish(TopicArn=topic_arn, Subject="Negative ticket alert", Message=alert)
        published = True

    return {
        "statusCode": 200,
        "body": json.dumps({
            "ticketId": ticket_id, "text": text, "sentiment": sentiment,
            "compound": compound, "stored": True, "published_to_sns": published
        })
    }
