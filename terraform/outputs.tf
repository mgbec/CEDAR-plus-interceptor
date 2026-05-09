output "rate_limiter_lambda_arn" {
  description = "ARN of the rate limiter Lambda (use in agentcore.json interceptor config)"
  value       = aws_lambda_function.rate_limiter.arn
}

output "db_tools_lambda_arn" {
  description = "ARN of the db-tools Lambda (use in agentcore.json target config)"
  value       = aws_lambda_function.db_tools.arn
}

output "gateway_role_arn" {
  description = "ARN of the gateway service role (use in agentcore.json or gateway_create)"
  value       = aws_iam_role.gateway.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB rate limits table"
  value       = aws_dynamodb_table.rate_limits.name
}

# --- Cognito Outputs ---

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_app_client_id" {
  description = "Cognito App Client ID (use as allowed_clients in agentcore.json)"
  value       = aws_cognito_user_pool_client.agent.id
}

output "cognito_app_client_secret" {
  description = "Cognito App Client Secret (sensitive — use for token requests)"
  value       = aws_cognito_user_pool_client.agent.client_secret
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito hosted UI domain"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "cognito_discovery_url" {
  description = "OIDC discovery URL — use this in agentcore.json authorizerConfiguration"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/openid-configuration"
}

output "cognito_issuer" {
  description = "Token issuer URL (for manual JWT validation)"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "cognito_token_endpoint" {
  description = "Token endpoint for programmatic auth"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

# --- Test Users ---

output "test_users" {
  description = "Test user emails (password is the test_user_password variable)"
  value = {
    admin       = "admin@example.com"
    engineering = "engineer@example.com"
    marketing   = "marketing@example.com"
  }
}

# --- Next Steps ---

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. Copy ARNs into agentcore.json:
       - rate_limiter_lambda_arn  → interceptorConfigurations[].interceptor.lambda.arn
       - db_tools_lambda_arn     → targets[].lambdaArn
       - cognito_discovery_url   → authorizerConfiguration.customJWTAuthorizer.discoveryUrl
       - cognito_app_client_id   → authorizerConfiguration.customJWTAuthorizer.allowedClients[]
    2. Run: agentcore deploy -y
    3. Get a test token: ./scripts/get-token.sh engineer@example.com
    4. Test with curl (see README.md)
  EOT
}
