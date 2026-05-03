output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB Zone ID for Route 53"
  value       = aws_lb.main.zone_id
}

output "compose_endpoint" {
  description = "Compose API endpoint"
  value       = "http://${aws_lb.main.dns_name}/api/v1/announcements"
}

output "read_endpoint" {
  description = "Read API endpoint"
  value       = "http://${aws_lb.main.dns_name}/api/v1/announcements"
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.announcements.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.announcements.arn
}

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = aws_sqs_queue.email_jobs.url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN"
  value       = aws_sqs_queue.email_jobs.arn
}

output "sqs_dlq_url" {
  description = "SQS DLQ URL"
  value       = aws_sqs_queue.email_jobs_dlq.url
}

output "ecr_repositories" {
  description = "ECR repository URLs"
  value = {
    storage = aws_ecr_repository.services["storage"].repository_url
    compose = aws_ecr_repository.services["compose"].repository_url
    read    = aws_ecr_repository.services["read"].repository_url
    worker  = aws_ecr_repository.services["worker"].repository_url
  }
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.scheduler.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.scheduler.arn
}

output "service_discovery_namespace" {
  description = "Service Discovery namespace for internal DNS"
  value       = aws_service_discovery_private_dns_namespace.internal.name
}

output "storage_service_name" {
  description = "Storage service discovery name (use: http://storage.internal:8080)"
  value       = "http://storage.internal:8080"
}

output "cloudwatch_log_groups" {
  description = "CloudWatch log group names"
  value = {
    storage = aws_cloudwatch_log_group.services["storage"].name
    compose = aws_cloudwatch_log_group.services["compose"].name
    read    = aws_cloudwatch_log_group.services["read"].name
    worker  = aws_cloudwatch_log_group.services["worker"].name
    lambda  = aws_cloudwatch_log_group.lambda.name
  }
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "deployment_steps" {
  description = "Quick deployment steps"
  value = <<-EOT
    1. Create scheduler.zip:
       cd ../scheduler && dotnet lambda package -o ../infra/scheduler.zip && cd ../infra

    2. Initialize Terraform:
       terraform init

    3. Deploy infrastructure:
       terraform plan
       terraform apply

    4. Build and push Docker images:
       aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
       
       For each service (storage, compose, read, worker):
       docker build --platform linux/amd64 -t email-platform/SERVICE:latest ../SERVICE
       docker tag email-platform/SERVICE:latest $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/email-platform/SERVICE:latest
       docker push $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/email-platform/SERVICE:latest

    5. Verify deployment:
       ALB DNS: ${aws_lb.main.dns_name}
       Compose: http://${aws_lb.main.dns_name}/api/v1/announcements
       Read: http://${aws_lb.main.dns_name}/api/v1/announcements?managerId=test

    6. Monitor:
       Storage logs: aws logs tail /ecs/email-platform-storage --follow
       Worker logs: aws logs tail /ecs/email-platform-worker --follow
       Lambda logs: aws logs tail /aws/lambda/email-platform-scheduler --follow
  EOT
}
