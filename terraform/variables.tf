variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "multi-tenant-db-agent"
}

variable "test_user_password" {
  description = "Temporary password for test users (must meet Cognito policy: 8+ chars, upper, lower, number)"
  type        = string
  sensitive   = true
  default     = "TestPass1"
}

variable "rate_limit_admins" {
  description = "Requests per hour for admins"
  type        = number
  default     = 100
}

variable "rate_limit_engineering" {
  description = "Requests per hour for engineering"
  type        = number
  default     = 50
}

variable "rate_limit_marketing" {
  description = "Requests per hour for marketing"
  type        = number
  default     = 20
}

variable "rate_limit_default" {
  description = "Requests per hour for unrecognized roles"
  type        = number
  default     = 10
}

# --- Policy Engine (created via scripts/create-policies.sh) ---

variable "policy_engine_arn" {
  description = "ARN of the AgentCore Policy Engine (auto-populated by scripts/create-policies.sh into policy-arns.auto.tfvars)"
  type        = string
  default     = ""
}

variable "policy_engine_id" {
  description = "ID of the AgentCore Policy Engine (auto-populated by scripts/create-policies.sh into policy-arns.auto.tfvars)"
  type        = string
  default     = ""
}
