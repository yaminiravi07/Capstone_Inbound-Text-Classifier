# Capstone — Inbound Text Classifier & Alerting Service

**Course:** BST-CS4BD-07 · **Region:** us-east-1 · **Compute:** serverless (Lambda)
**Team:** Yamini Ravi & Meenakshy Kattungal Roshan · **Team account:** Yamini Ravi's Lab

---

## What it does

A serverless service that receives text (support tickets / product reviews), classifies
its sentiment, stores every ticket, and fans out an alert to multiple channels when a
ticket is negative. The full request flow:

1. **API Gateway** exposes a public POST endpoint (`/notify`). Requests must carry the
   correct `x-api-key` header or they are rejected with HTTP 403.
2. **Ingress Lambda** (`capstone-phase2-fn`, runs under LabRole) validates the request and
   scores sentiment **in-process using the VADER library** (bundled into the deployment
   package — no external NLP service, works with no extra AWS permissions).
3. Every ticket — positive, negative or neutral — is written to **DynamoDB**
   (`capstone-tickets`, on-demand / PAY_PER_REQUEST) as the permanent record.
4. If the ticket is **NEGATIVE**, the Lambda **publishes to an SNS topic**
   (`capstone-alerts`), which **fans out to three consumers**:
   - **Email** subscription (support lead).
   - **Telegram notifier Lambda** (`capstone-notifier-fn`) — calls the external
     **Telegram Bot API** (our outside-AWS integration) and delivers the alert to a chat.
   - **Archival Lambda** (`capstone-archival-fn`) — logs the alert for the record.
5. The **Telegram bot token** is read from **AWS Secrets Manager** at runtime — never
   hard-coded, never in this archive.
6. **CloudWatch** provides observability: an error alarm (`capstone-lambda-errors`) and a
   dashboard (`capstone-dashboard`) of invocations, errors and duration.

Positive/neutral tickets are stored but do NOT trigger the fan-out — alerts are for
complaints only.

## AWS services used

| Role                 | Service                                   |
|----------------------|-------------------------------------------|
| Compute              | AWS Lambda (3 functions)                  |
| Public ingress       | Amazon API Gateway (HTTP API, POST)       |
| Intelligence         | In-Lambda VADER sentiment (no AWS perms)  |
| Persistent state     | Amazon DynamoDB (on-demand)               |
| Fan-out              | Amazon SNS (email + 2 Lambda consumers)   |
| External integration | Telegram Bot API (outside AWS)            |
| Secret management     | AWS Secrets Manager                      |
| Observability        | Amazon CloudWatch (alarm + dashboard)     |

## Files

    main.tf                 All infrastructure (Terraform).
    src/handler.py          Ingress Lambda: auth, VADER, DynamoDB write, SNS publish.
    src_notifier/handler.py Telegram notifier Lambda (SNS consumer).
    src_archival/handler.py Archival Lambda (SNS consumer).

Note: `src/` must also contain the bundled `vaderSentiment` library at apply time
(installed with pip — see step 2 below). It is intentionally NOT committed here.

---

## How to apply it

Prerequisites: the AWS Learner Lab running (region us-east-1), Terraform on PATH, and
active lab credentials in the terminal.

1. **Bundle the VADER library into src/** (it is a dependency, not committed):

       cd <this folder>
       pip install vaderSentiment -t src/ --break-system-packages

   Verify: `ls src/` shows `handler.py` PLUS a `vaderSentiment/` folder.

2. **Deploy:**

       terraform init
       terraform apply        # type: yes

   If you hit `ResourceInUseException: Table already exists: capstone-tickets`
   (a table left from a previous session), import it instead of creating it:

       terraform import aws_dynamodb_table.tickets capstone-tickets
       terraform apply

3. **Set the secret OUT OF BAND** (never in code, never in this archive):

       aws secretsmanager put-secret-value \
         --secret-id capstone/phase2/telegram \
         --secret-string '{"telegram_token":"YOUR_TOKEN","chat_id":"YOUR_CHAT_ID","api_key":"YOUR_API_KEY"}' \
         --region us-east-1

4. **Confirm the email subscription:** AWS emails a "Confirm subscription" link to the
   address in `main.tf`. Click it, or the email consumer stays pending.

5. **Get the endpoint:**

       terraform output invoke_url

## How to test

Negative ticket -> stored, and fans out to email + Telegram + archival:

    curl -i -X POST -H "x-api-key: YOUR_API_KEY" -H "Content-Type: application/json" \
      -d '{"text":"This is broken and I want a refund, terrible experience"}' "INVOKE_URL"
    # -> "sentiment":"NEGATIVE", "stored":true, "published_to_sns":true

Positive ticket -> stored only, no fan-out:

    curl -i -X POST -H "x-api-key: YOUR_API_KEY" -H "Content-Type: application/json" \
      -d '{"text":"Amazing product, I love it!"}' "INVOKE_URL"
    # -> "sentiment":"POSITIVE", "published_to_sns":false

No key -> rejected:

    curl -i -X POST -H "Content-Type: application/json" -d '{"text":"hi"}' "INVOKE_URL"
    # -> HTTP 403 Forbidden

Inspect stored tickets / archival logs:

    aws dynamodb scan --table-name capstone-tickets --region us-east-1
    aws logs tail /aws/lambda/capstone-archival-fn --region us-east-1 --since 10m

## Tear down

    terraform destroy          # type: yes

---

## Design notes

- **Telegram** is the required external, outside-AWS integration (per instructor
  feedback that Amazon Comprehend, being an AWS service, does not qualify).
- **Amazon Comprehend was tested in the Learner Lab and is BLOCKED** (AccessDeniedException;
  the voclabs role grants no `comprehend:*`). Sentiment therefore runs in-Lambda with
  VADER, which needs no AWS permissions and cannot be blocked.
- **LabRole is referenced via a data source**; we never create an IAM role (the lab denies
  `iam:CreateRole`).
- The CloudWatch alarm uses `treat_missing_data = "notBreaching"` because the service is
  mostly idle — silence should not be treated as a failure.

## Security

- No secrets or credentials are included in this archive. The Telegram token lives only in
  Secrets Manager, set via the CLI command in step 3.
- Do not commit `build/`, `.terraform/`, `terraform.tfstate*`, or the bundled
  `src/vaderSentiment/` folder.
