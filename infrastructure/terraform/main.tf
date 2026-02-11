terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Groups
resource "aws_security_group" "api" {
  name        = "${var.project_name}-api-sg"
  description = "Security group for API servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-api-sg"
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-worker-sg"
  description = "Security group for worker nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-worker-sg"
  }
}

# SQS Queues
resource "aws_sqs_queue" "main" {
  name                       = "${var.project_name}-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "${var.project_name}-queue"
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-dlq"
  message_retention_seconds = 1209600

  tags = {
    Name = "${var.project_name}-dlq"
  }
}

# DynamoDB Table
resource "aws_dynamodb_table" "events" {
  name           = "${var.project_name}-events"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "event_type"
    type = "S"
  }

  attribute {
    name = "submitted_at"
    type = "S"
  }

  global_secondary_index {
    name            = "event_type-index"
    hash_key        = "event_type"
    range_key       = "submitted_at"
    projection_type = "ALL"
  }

  tags = {
    Name = "${var.project_name}-events"
  }
}

# IAM Roles
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:*",
          "dynamodb:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Load Balancer
resource "aws_lb" "api" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.api.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "api" {
  name     = "${var.project_name}-api-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 30
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Launch Template for API
resource "aws_launch_template" "api" {
  name_prefix   = "${var.project_name}-api-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.api_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.api.id]

  user_data = base64encode(templatefile("${path.module}/user_data_api.sh", {
    sqs_queue_url       = aws_sqs_queue.main.url
    dynamodb_table_name = aws_dynamodb_table.events.name
    aws_region          = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-api"
    }
  }
}

# Auto Scaling Group for API
resource "aws_autoscaling_group" "api" {
  name                = "${var.project_name}-api-asg"
  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.api.arn]
  health_check_type   = "ELB"
  min_size            = 2
  max_size            = 10
  desired_capacity    = 2

  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-api"
    propagate_at_launch = true
  }
}

# Launch Template for Workers
resource "aws_launch_template" "worker" {
  name_prefix   = "${var.project_name}-worker-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.worker_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.worker.id]

  user_data = base64encode(templatefile("${path.module}/user_data_worker.sh", {
    sqs_queue_url       = aws_sqs_queue.main.url
    sqs_dlq_url         = aws_sqs_queue.dlq.url
    dynamodb_table_name = aws_dynamodb_table.events.name
    aws_region          = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-worker"
    }
  }
}

# Auto Scaling Group for Workers
resource "aws_autoscaling_group" "worker" {
  name                = "${var.project_name}-worker-asg"
  vpc_zone_identifier = aws_subnet.public[*].id
  min_size            = 3
  max_size            = 20
  desired_capacity    = 3

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-worker"
    propagate_at_launch = true
  }
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "worker_scale_up" {
  name                   = "${var.project_name}-worker-scale-up"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.worker.name
}

resource "aws_autoscaling_policy" "worker_scale_down" {
  name                   = "${var.project_name}-worker-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.worker.name
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "queue_depth_high" {
  alarm_name          = "${var.project_name}-queue-depth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Average"
  threshold           = "1000"
  alarm_description   = "This metric monitors SQS queue depth"
  alarm_actions       = [aws_autoscaling_policy.worker_scale_up.arn]

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_depth_low" {
  alarm_name          = "${var.project_name}-queue-depth-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "300"
  statistic           = "Average"
  threshold           = "100"
  alarm_description   = "This metric monitors SQS queue depth"
  alarm_actions       = [aws_autoscaling_policy.worker_scale_down.arn]

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }
}

# Data Sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}
