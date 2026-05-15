# =============================================================
# AgentCore Gateway + Gateway Target
# =============================================================
# The Policy Engine and Cedar Policies are created via the
# scripts/create-policies.sh script (API-based), since the
# Terraform AWS provider doesn't support those resources yet.
#
# The script writes policy_engine_arn to policy-arns.auto.tfvars,
# which Terraform picks up automatically.
# =============================================================

# --- Gateway ---

resource "aws_bedrockagentcore_gateway" "main" {
  name          = "DataPlatformGateway"
  description   = "Gateway for internal data platform tools"
  protocol_type = "MCP"
  role_arn      = aws_iam_role.gateway.arn

  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/openid-configuration"
      allowed_clients = [aws_cognito_user_pool_client.agent.id]
    }
  }

  protocol_configuration {
    mcp {
      search_type  = "SEMANTIC"
      instructions = "Database tools for querying, listing, and managing records in the shared data platform."
    }
  }

  interceptor_configuration {
    interceptor {
      lambda {
        arn = aws_lambda_function.rate_limiter.arn
      }
    }
    interception_points = ["REQUEST"]
    input_configuration {
      pass_request_headers = true
    }
  }

  exception_level = "DEBUG"

  tags = {
    Project = var.project_name
  }
}

# --- Gateway Target (Lambda) ---

resource "aws_bedrockagentcore_gateway_target" "database_tools" {
  name               = "DatabaseTools"
  description        = "Lambda function target for database tools"
  gateway_identifier = aws_bedrockagentcore_gateway.main.gateway_id

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.db_tools.arn
        tool_schema {
          inline_payload {
            name        = "run_query"
            description = "Execute a read-only SQL query against the shared database"
            input_schema {
              type = "object"
              property {
                name        = "sql"
                type        = "string"
                description = "The SQL SELECT query to execute"
                required    = true
              }
              property {
                name        = "database"
                type        = "string"
                description = "Target database name"
                required    = true
              }
            }
          }
          inline_payload {
            name        = "list_tables"
            description = "List all tables in a database with their row counts"
            input_schema {
              type = "object"
              property {
                name        = "database"
                type        = "string"
                description = "Target database name"
                required    = true
              }
            }
          }
          inline_payload {
            name        = "delete_records"
            description = "Delete records matching a condition from a table"
            input_schema {
              type = "object"
              property {
                name        = "table"
                type        = "string"
                description = "Table to delete from"
                required    = true
              }
              property {
                name        = "condition"
                type        = "string"
                description = "WHERE clause condition for deletion"
                required    = true
              }
              property {
                name        = "database"
                type        = "string"
                description = "Target database name"
                required    = true
              }
            }
          }
          inline_payload {
            name        = "describe_table"
            description = "Get schema details for a specific table"
            input_schema {
              type = "object"
              property {
                name        = "table"
                type        = "string"
                description = "Table name to describe"
                required    = true
              }
              property {
                name        = "database"
                type        = "string"
                description = "Target database name"
                required    = true
              }
            }
          }
        }
      }
    }
  }

  credential_provider_configuration {
    gateway_iam_role {}
  }
}
