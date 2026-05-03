variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "me-south-1"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "email-platform"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["me-south-1a", "me-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name"
  type        = string
  default     = "Announcements"
}

variable "sqs_queue_name" {
  description = "SQS queue name"
  type        = string
  default     = "email-jobs"
}

variable "sqs_dlq_name" {
  description = "SQS DLQ name"
  type        = string
  default     = "email-jobs-dlq"
}

variable "sqs_visibility_timeout" {
  description = "SQS visibility timeout (seconds)"
  type        = number
  default     = 60
}

variable "sqs_max_receive_count" {
  description = "SQS max receive count before DLQ"
  type        = number
  default     = 3
}

variable "sqs_message_retention_period" {
  description = "SQS message retention (seconds, 4 days)"
  type        = number
  default     = 345600
}

variable "sqs_dlq_retention_period" {
  description = "SQS DLQ retention (seconds, 14 days)"
  type        = number
  default     = 1209600
}

variable "ses_email_identity" {
  description = "Email to verify with SES"
  type        = string
  default     = "noreply@yourdomain.com"
}

variable "ecs_task_cpu" {
  description = "ECS task CPU"
  type        = string
  default     = "256"
}

variable "ecs_task_memory" {
  description = "ECS task memory (MB)"
  type        = string
  default     = "512"
}

variable "container_port" {
  description = "Container port"
  type        = number
  default     = 8080
}

variable "lambda_memory" {
  description = "Lambda memory (MB)"
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Lambda timeout (seconds)"
  type        = number
  default     = 60
}

variable "scheduler_handler" {
  description = "Lambda handler"
  type        = string
  default     = "Scheduler.Lambda::EmailPlatform.Scheduler.Function::Handle"
}

variable "eventbridge_cron" {
  description = "EventBridge cron (Thursday 9am UTC)"
  type        = string
  default     = "cron(0 9 ? * THU *)"
}
