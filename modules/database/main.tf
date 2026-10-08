resource "aws_dynamodb_table" "jobs" {
  name         = "GreenQueueJobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "grid" {
  name         = "GreenQueueGrid"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "hour"

  attribute {
    name = "hour"
    type = "S"
  }
}