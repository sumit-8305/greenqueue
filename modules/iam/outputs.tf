output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "worker_instance_profile_name" {
  value = aws_iam_instance_profile.worker.name
}

output "monitoring_instance_profile_name" {
  value = aws_iam_instance_profile.monitoring.name
}