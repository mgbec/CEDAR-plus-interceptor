terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region
}

# =============================================================
# DynamoDB Table — Rate Limit Counters
# =============================================================

resource "aws_dynamodb_table" "rate_limits" {
  name         = "${var.project_name}-rate-limits"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Project = var.project_name
  }
}

# =============================================================
# IAM — Lambda Execution Roles
# =============================================================

# Shared assume-role policy for Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Rate Limiter Role ---

resource "aws_iam_role" "rate_limiter" {
  name               = "${var.project_name}-rate-limiter"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "rate_limiter_basic" {
  role       = aws_iam_role.rate_limiter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "rate_limiter_dynamo" {
  statement {
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.rate_limits.arn]
  }
}

resource "aws_iam_policy" "rate_limiter_dynamo" {
  name   = "${var.project_name}-rate-limiter-dynamo"
  policy = data.aws_iam_policy_document.rate_limiter_dynamo.json
}

resource "aws_iam_role_policy_attachment" "rate_limiter_dynamo" {
  role       = aws_iam_role.rate_limiter.name
  policy_arn = aws_iam_policy.rate_limiter_dynamo.arn
}

# --- DB Tools Role ---

resource "aws_iam_role" "db_tools" {
  name               = "${var.project_name}-db-tools"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "db_tools_basic" {
  role       = aws_iam_role.db_tools.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# =============================================================
# Lambda — Rate Limiter (Gateway Interceptor)
# =============================================================

data "archive_file" "rate_limiter" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/rate-limiter/index.py"
  output_path = "${path.module}/.build/rate-limiter.zip"
}

resource "aws_lambda_function" "rate_limiter" {
  function_name    = "${var.project_name}-rate-limiter"
  role             = aws_iam_role.rate_limiter.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.rate_limiter.output_path
  source_code_hash = data.archive_file.rate_limiter.output_base64sha256

  environment {
    variables = {
      RATE_LIMIT_TABLE       = aws_dynamodb_table.rate_limits.name
      RATE_LIMIT_ADMINS      = tostring(var.rate_limit_admins)
      RATE_LIMIT_ENGINEERING = tostring(var.rate_limit_engineering)
      RATE_LIMIT_MARKETING   = tostring(var.rate_limit_marketing)
      RATE_LIMIT_DEFAULT     = tostring(var.rate_limit_default)
    }
  }

  tags = {
    Project = var.project_name
  }
}

# Allow AgentCore Gateway to invoke the rate limiter
resource "aws_lambda_permission" "rate_limiter_gateway" {
  statement_id   = "AllowAgentCoreGatewayInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rate_limiter.function_name
  principal      = "bedrock-agentcore.amazonaws.com"
  source_account = local.account_id
}

# =============================================================
# Lambda — DB Tools (Backend Tool Implementation)
# =============================================================

data "archive_file" "db_tools" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/db-tools/index.py"
  output_path = "${path.module}/.build/db-tools.zip"
}

resource "aws_lambda_function" "db_tools" {
  function_name    = "${var.project_name}-db-tools"
  role             = aws_iam_role.db_tools.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.db_tools.output_path
  source_code_hash = data.archive_file.db_tools.output_base64sha256

  tags = {
    Project = var.project_name
  }
}

# Allow AgentCore Gateway to invoke the db-tools Lambda
resource "aws_lambda_permission" "db_tools_gateway" {
  statement_id   = "AllowAgentCoreGatewayInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.db_tools.function_name
  principal      = "bedrock-agentcore.amazonaws.com"
  source_account = local.account_id
}

# =============================================================
# IAM — Gateway Service Role
# =============================================================

data "aws_iam_policy_document" "gateway_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.project_name}-gateway-role"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "gateway_permissions" {
  # Allow the gateway to invoke both Lambda functions
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.db_tools.arn,
      "${aws_lambda_function.db_tools.arn}:*",
      aws_lambda_function.rate_limiter.arn,
      "${aws_lambda_function.rate_limiter.arn}:*",
    ]
  }

  # Allow the gateway to use the policy engine for authorization
  statement {
    actions = [
      "bedrock-agentcore:AuthorizeAction",
      "bedrock-agentcore:CheckAuthorizePermissions",
      "bedrock-agentcore:GetPolicyEngine",
      "bedrock-agentcore:PartiallyAuthorizeActions",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:gateway/*",
      "arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:policy-engine/*",
    ]
  }
}

resource "aws_iam_policy" "gateway_permissions" {
  name   = "${var.project_name}-gateway-permissions"
  policy = data.aws_iam_policy_document.gateway_permissions.json
}

resource "aws_iam_role_policy_attachment" "gateway_permissions" {
  role       = aws_iam_role.gateway.name
  policy_arn = aws_iam_policy.gateway_permissions.arn
}
