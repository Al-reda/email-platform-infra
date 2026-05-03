terraform {
  required_version = ">= 1.0"
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

# ============================================================================
# VPC & NETWORKING
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.app_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.app_name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = { Name = "${var.app_name}-private-${count.index + 1}" }
}

# Cost Optimization: Single NAT Gateway shared across private subnets
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.app_name}-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.app_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.app_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================================
# SECURITY GROUPS (Decoupled rules to prevent circular dependencies)
# ============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${var.app_name}-alb-"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.app_name}-alb-sg" }
}

resource "aws_security_group" "app_tasks" {
  name_prefix = "${var.app_name}-tasks-"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.app_name}-tasks-sg" }
}

resource "aws_security_group_rule" "alb_ingress_80" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "tasks_ingress_from_alb" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app_tasks.id
}

resource "aws_security_group_rule" "tasks_internal_comms" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  self                     = true
  security_group_id        = aws_security_group.app_tasks.id
}

resource "aws_security_group_rule" "tasks_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app_tasks.id
}

# ============================================================================
# DYNAMODB
# ============================================================================

resource "aws_dynamodb_table" "announcements" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "announcementId"

  attribute { 
    name = "managerId"      
    type = "S" 
    }
  attribute { 
    name = "announcementId" 
    type = "S" 
    }
  attribute { 
    name = "createdAt"      
    type = "S" 
    }
  attribute { 
    name = "status"         
    type = "S" 
    }
  attribute { 
    name = "scheduledFor"   
    type = "S" 
    }

  global_secondary_index {
    name            = "by-manager-index"
    hash_key        = "managerId"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "by-status-index"
    hash_key        = "status"
    range_key       = "scheduledFor"
    projection_type = "ALL"
  }

  tags = { Name = "${var.app_name}-announcements" }
}

# ============================================================================
# SQS & SES
# ============================================================================

resource "aws_sqs_queue" "email_jobs_dlq" {
  name                      = "${var.sqs_queue_name}-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "email_jobs" {
  name                       = var.sqs_queue_name
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.email_jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.ses_email_identity
}

# ============================================================================
# ECR & CLOUDWATCH
# ============================================================================

resource "aws_ecr_repository" "services" {
  for_each = toset(["storage", "compose", "read", "worker"])
  name     = "${var.app_name}/${each.value}"
  force_delete = true
}

resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(["storage", "compose", "read", "worker"])
  name              = "/ecs/${var.app_name}-${each.value}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.app_name}-scheduler"
  retention_in_days = 7
  tags              = { Name = "${var.app_name}-lambda-logs" }
}

# ============================================================================
# IAM ROLES
# ============================================================================

resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.app_name}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "app_task_role" {
  name = "${var.app_name}-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "app_permissions" {
  name = "${var.app_name}-app-permissions"
  role = aws_iam_role.app_task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:Scan"]
        Effect   = "Allow"
        Resource = [aws_dynamodb_table.announcements.arn, "${aws_dynamodb_table.announcements.arn}/index/*"]
      },
      {
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:SendMessage"]
        Effect   = "Allow"
        Resource = [aws_sqs_queue.email_jobs.arn]
      },
      {
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# ECS CLUSTER & SERVICE DISCOVERY
# ============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"
}

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = "internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "storage" {
  name = "storage"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
       type = "A"
       ttl = 10 
       }
  }
}

# ============================================================================
# ECS SERVICES (Storage, Compose, Read, Worker)
# ============================================================================

# Storage Service
resource "aws_ecs_task_definition" "storage" {
  family                   = "${var.app_name}-storage"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.app_task_role.arn

  container_definitions = jsonencode([{
    name      = "storage"
    image     = "${aws_ecr_repository.services["storage"].repository_url}:latest"
    portMappings = [{ containerPort = var.container_port }]
    environment = [
      { name = "STORAGE__TABLENAME", value = aws_dynamodb_table.announcements.name },
      { name = "STORAGE__REGION", value = var.aws_region },
      { name = "STORAGE__SERVICEURL", value = "" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.services["storage"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "storage" {
  name            = "storage"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.storage.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.app_tasks.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.storage.arn
  }
}

# Compose Service
resource "aws_ecs_task_definition" "compose" {
  family                   = "${var.app_name}-compose"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.app_task_role.arn

  container_definitions = jsonencode([{
    name      = "compose"
    image     = "${aws_ecr_repository.services["compose"].repository_url}:latest"
    portMappings = [{ containerPort = var.container_port }]
    environment = [{ name = "STORAGECLIENT__BASEURL", value = "http://storage.internal:${var.container_port}" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.services["compose"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "compose" {
  name            = "compose"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.compose.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.app_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.compose.arn
    container_name   = "compose"
    container_port   = var.container_port
  }
}

# Read Service
resource "aws_ecs_task_definition" "read" {
  family                   = "${var.app_name}-read"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.app_task_role.arn

  container_definitions = jsonencode([{
    name      = "read"
    image     = "${aws_ecr_repository.services["read"].repository_url}:latest"
    portMappings = [{ containerPort = var.container_port }]
    environment = [{ name = "STORAGECLIENT__BASEURL", value = "http://storage.internal:${var.container_port}" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.services["read"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "read" {
  name            = "read"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.read.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.app_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.read.arn
    container_name   = "read"
    container_port   = var.container_port
  }
}

# Worker Service
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.app_name}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.app_task_role.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.services["worker"].repository_url}:latest"
    environment = [
      { name = "EMAIL__QUEUEURL", value = aws_sqs_queue.email_jobs.url },
      { name = "EMAIL__SENDER", value = var.ses_email_identity },
      { name = "EMAIL__REGION", value = var.aws_region },
      { name = "EMAIL__RECEIVEWAITSECONDS", value = "20" },
      { name = "STORAGECLIENT__BASEURL", value = "http://storage.internal:${var.container_port}" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.services["worker"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.app_tasks.id]
  }
}

# ============================================================================
# LOAD BALANCER SETUP
# ============================================================================

resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "compose" {
  name        = "${var.app_name}-compose-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health" }
}

resource "aws_lb_target_group" "read" {
  name        = "${var.app_name}-read-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.compose.arn
  }
}

resource "aws_lb_listener_rule" "compose_post_put" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.compose.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/announcements"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "PUT"]
    }
  }
}

resource "aws_lb_listener_rule" "read_get" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.read.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/announcements"]
    }
  }

  condition {
    http_request_method {
      values = ["GET"]
    }
  }
}

# ============================================================================
# LAMBDA SCHEDULER
# ============================================================================

resource "aws_iam_role" "lambda_role" {
  name = "${var.app_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs_logs" {
  name = "${var.app_name}-lambda-sqs-logs"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["sqs:SendMessage"]
        Effect   = "Allow"
        Resource = aws_sqs_queue.email_jobs.arn
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "scheduler" {
  filename      = "scheduler.zip"
  function_name = "${var.app_name}-scheduler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "Scheduler.Lambda::EmailPlatform.Scheduler.Function::Handle"
  runtime       = "provided.al2"
  timeout       = 60
  memory_size   = 256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.app_tasks.id]
  }

  environment {
    variables = {
      SCHEDULER__QUEUEURL       = aws_sqs_queue.email_jobs.url
      STORAGECLIENT__BASEURL    = "http://storage.internal:${var.container_port}"
      SCHEDULER__REGION         = var.aws_region
    }
  }
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduler.arn
}

resource "aws_cloudwatch_event_rule" "scheduler" {
  name                = "${var.app_name}-scheduler-rule"
  description         = "Trigger scheduler Lambda every Thursday at 9am UTC"
  schedule_expression = "cron(0 9 ? * THU *)"
}

resource "aws_cloudwatch_event_target" "scheduler" {
  rule      = aws_cloudwatch_event_rule.scheduler.name
  target_id = "${var.app_name}-scheduler-lambda"
  arn       = aws_lambda_function.scheduler.arn

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 1
  }
}