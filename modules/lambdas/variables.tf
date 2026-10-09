variable "lambda_role_arn" { type = string }
variable "jobs_table_name" { type = string }
variable "grid_table_name" { type = string }
variable "queue_url" { type = string }

variable "em_api_key" {
  type      = string
  sensitive = true
}

variable "em_zone" { type = string }