data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "worker" {
  name        = "greenqueue-worker-sg"
  description = "Workers: node_exporter from inside the VPC only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "worker" {
  name_prefix            = "greenqueue-worker-"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.worker.id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    worker_py  = file("${path.root}/worker/worker.py")
    region     = data.aws_region.current.region
    jobs_table = var.jobs_table_name
    grid_table = var.grid_table_name
    queue_url  = var.queue_url
    asg_name   = var.asg_name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "greenqueue-worker"
      project = "greenqueue"
      role    = "worker"
    }
  }
}

resource "aws_autoscaling_group" "workers" {
  name                = var.asg_name
  min_size            = 0
  max_size            = var.max_size
  desired_capacity    = 0
  vpc_zone_identifier = data.aws_subnets.default.ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ---- scale on SQS queue depth ----
resource "aws_autoscaling_policy" "scale_out" {
  name                      = "greenqueue-scale-out"
  autoscaling_group_name    = aws_autoscaling_group.workers.name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  metric_aggregation_type   = "Maximum"
  estimated_instance_warmup = 120

  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 4
    scaling_adjustment          = 1
  }
  step_adjustment {
    metric_interval_lower_bound = 4
    scaling_adjustment          = 2
  }
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "greenqueue-scale-to-zero"
  autoscaling_group_name = aws_autoscaling_group.workers.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ExactCapacity"
  scaling_adjustment     = 0
  cooldown               = 60
}

resource "aws_cloudwatch_metric_alarm" "backlog_high" {
  alarm_name          = "greenqueue-backlog-high"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_empty" {
  alarm_name          = "greenqueue-queue-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]
}