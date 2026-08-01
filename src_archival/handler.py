import json

def lambda_handler(event, context):
    for record in event.get("Records", []):
        print("ARCHIVE:", record["Sns"]["Message"])
    return {"statusCode": 200}
