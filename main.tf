terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Reference the pre-created LabRole (do NOT create a role)
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# ================= SECRETS =================
# Holds telegram_token, chat_id and api_key. VALUE SET OUT OF BAND (see README).
resource "aws_secretsmanager_secret" "telegram" {
  name = "capstone/phase2/telegram"
}

# ================= MAIN INGRESS LAMBDA =================
# src/ must contain handler.py AND the bundled vaderSentiment library.
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = "capstone-phase2-fn"
  role             = data.aws_iam_role.lab_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.telegram.name
      TABLE_NAME  = aws_dynamodb_table.tickets.name
      TOPIC_ARN   = aws_sns_topic.alerts.arn
    }
  }
}

# ================= PUBLIC FRONT DOOR: API GATEWAY (POST) =================
resource "aws_apigatewayv2_api" "http_api" {
  name          = "capstone-phase2-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.notifier.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /notify"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ================= PERSISTENT STATE: DYNAMODB =================
resource "aws_dynamodb_table" "tickets" {
  name         = "capstone-tickets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticketId"

  attribute {
    name = "ticketId"
    type = "S"
  }
}

# ================= SNS FAN-OUT (3 CONSUMERS) =================
resource "aws_sns_topic" "alerts" {
  name = "capstone-alerts"
}

# Consumer 1: email subscription (must be confirmed via the link AWS emails)
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "Yamini.Ravi@stud.srh-university.de"
}

# ---- Consumer 2: Telegram notifier Lambda ----
data "archive_file" "notifier_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src_notifier"
  output_path = "${path.module}/build/notifier.zip"
}

resource "aws_lambda_function" "notifier_fn" {
  function_name    = "capstone-notifier-fn"
  role             = data.aws_iam_role.lab_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.notifier_zip.output_path
  source_code_hash = data.archive_file.notifier_zip.output_base64sha256
  timeout          = 15
  environment {
    variables = { SECRET_NAME = aws_secretsmanager_secret.telegram.name }
  }
}

resource "aws_sns_topic_subscription" "telegram" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notifier_fn.arn
}

resource "aws_lambda_permission" "sns_notifier" {
  statement_id  = "AllowSNSInvokeNotifier"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier_fn.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# ---- Consumer 3: Archival Lambda ----
data "archive_file" "archival_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src_archival"
  output_path = "${path.module}/build/archival.zip"
}

resource "aws_lambda_function" "archival_fn" {
  function_name    = "capstone-archival-fn"
  role             = data.aws_iam_role.lab_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.archival_zip.output_path
  source_code_hash = data.archive_file.archival_zip.output_base64sha256
  timeout          = 15
}

resource "aws_sns_topic_subscription" "archival" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.archival_fn.arn
}

resource "aws_lambda_permission" "sns_archival" {
  statement_id  = "AllowSNSInvokeArchival"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archival_fn.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# ================= OBSERVABILITY: CLOUDWATCH =================
# Alarm fires if the main Lambda records 1+ errors in a 5-min window.
# treat_missing_data = notBreaching: an idle service should not alarm on silence.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "capstone-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Fires when the capstone Lambda records one or more errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.notifier.function_name
  }
}

resource "aws_cloudwatch_dashboard" "capstone" {
  dashboard_name = "capstone-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Lambda invocations & errors",
          region = "us-east-1",
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.notifier.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.notifier.function_name]
          ],
          period = 300, stat = "Sum"
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Lambda duration",
          region = "us-east-1",
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.notifier.function_name]
          ],
          period = 300, stat = "Average"
        }
      }
    ]
  })
}

# ================= OUTPUTS =================
output "invoke_url" {
  value = "${aws_apigatewayv2_stage.default_stage.invoke_url}/notify"
}

output "table_name" {
  value = aws_dynamodb_table.tickets.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.capstone.dashboard_name
}
