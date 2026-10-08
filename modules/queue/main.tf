resource "aws_sqs_queue" "dlq" {
  name                      = "greenqueue-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "jobs" {
  name                       = "greenqueue-jobs"
  visibility_timeout_seconds = var.visibility_timeout
  receive_wait_time_seconds  = 20 # long polling
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}