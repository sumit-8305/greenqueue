data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.root}/lambda_src/api"
  output_path = "${path.module}/api.zip"
}

data "archive_file" "scheduler" {
  type        = "zip"
  source_dir  = "${path.root}/lambda_src/scheduler"
  output_path = "${path.module}/scheduler.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = "greenqueue-api"
  role             = var.lambda_role_arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      JOBS_TABLE = var.jobs_table_name
      GRID_TABLE = var.grid_table_name
    }
  }
}

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type"]
  }
}

resource "aws_lambda_permission" "api_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_function" "scheduler" {
  function_name    = "greenqueue-scheduler"
  role             = var.lambda_role_arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.scheduler.output_path
  source_code_hash = data.archive_file.scheduler.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      JOBS_TABLE = var.jobs_table_name
      GRID_TABLE = var.grid_table_name
      QUEUE_URL  = var.queue_url
    }
  }
}

resource "aws_cloudwatch_event_rule" "scheduler" {
  name                = "greenqueue-scheduler-tick"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "scheduler" {
  rule = aws_cloudwatch_event_rule.scheduler.name
  arn  = aws_lambda_function.scheduler.arn
}

resource "aws_lambda_permission" "scheduler_events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduler.arn
}




data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.root}/lambda_src/ingest"
  output_path = "${path.module}/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name    = "greenqueue-ingest"
  role             = var.ingest_lambda_role_arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  timeout          = 20

  environment {
    variables = {
      GRID_TABLE                = var.grid_table_name
      EM_ZONE                   = var.em_zone
      EM_API_KEY_PARAMETER_NAME = var.em_api_key_parameter_name
    }
  }
}

resource "aws_cloudwatch_event_rule" "ingest" {
  name                = "greenqueue-ingest-hourly"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "ingest" {
  rule = aws_cloudwatch_event_rule.ingest.name
  arn  = aws_lambda_function.ingest.arn
}

resource "aws_lambda_permission" "ingest_events" {
  statement_id  = "AllowEventBridgeIngest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingest.arn
}