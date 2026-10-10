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

resource "aws_security_group" "monitoring" {
  name        = "greenqueue-monitoring-sg"
  description = "No inbound access; use Systems Manager port forwarding"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "prometheus" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = var.instance_profile_name
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    exporter_py             = file("${path.module}/dynamodb_exporter.py")
    grafana_setup           = file("${path.module}/grafana_setup.sh")
    dashboard_json_gzip_b64 = base64gzip(file("${path.module}/greenqueue-dashboard.json"))
    region                  = var.region
    jobs_table              = var.jobs_table_name
    grid_table              = var.grid_table_name
    queue_url               = var.queue_url
  })
  user_data_replace_on_change = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }

  tags = {
    Name    = "greenqueue-prometheus"
    project = "greenqueue"
    role    = "monitoring"
  }
}
