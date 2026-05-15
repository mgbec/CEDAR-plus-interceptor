# =============================================================
# AgentCore Gateway + Policy Engine + Policies
# =============================================================
# Deploys the AgentCore resources that the agentcore CLI would
# normally handle via CDK. Using Terraform instead for a single
# unified deployment.
# =============================================================

# --- Policy Engine ---

resource "aws_bedrockagentcore_policy_engine" "main" {
  name        = "DataPlatformAuth"
  description = "Cedar authorization for the data platform gateway"

  tags = {
    Project = var.project_name
  }
}

# --- Cedar Policies ---

resource "aws_bedrockagentcore_policy" "admin_full_access" {
  name             = "AdminFullAccess"
  description      = "Admins can invoke all database tools without restriction"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"admins\", action == Action::\"InvokeTool\", resource);"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "engineering_run_query" {
  name             = "EngineeringRunQuery"
  description      = "Engineers can run queries"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"engineering\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___run_query\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "engineering_list_tables" {
  name             = "EngineeringListTables"
  description      = "Engineers can list tables"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"engineering\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___list_tables\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "engineering_describe_table" {
  name             = "EngineeringDescribeTable"
  description      = "Engineers can describe tables"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"engineering\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___describe_table\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "engineering_forbid_delete" {
  name             = "EngineeringForbidDelete"
  description      = "Engineers cannot delete records"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "forbid(principal in Group::\"engineering\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___delete_records\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "marketing_list_tables" {
  name             = "MarketingListTables"
  description      = "Marketing can list tables"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"marketing\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___list_tables\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "marketing_describe_table" {
  name             = "MarketingDescribeTable"
  description      = "Marketing can describe tables"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = "permit(principal in Group::\"marketing\", action == Action::\"InvokeTool\", resource == Tool::\"DatabaseTools___describe_table\");"
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

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

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.main.arn
    mode = "ENFORCE"
  }

  interceptor_configurations {
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

  depends_on = [
    aws_bedrockagentcore_policy.admin_full_access,
    aws_bedrockagentcore_policy.engineering_run_query,
    aws_bedrockagentcore_policy.engineering_list_tables,
    aws_bedrockagentcore_policy.engineering_describe_table,
    aws_bedrockagentcore_policy.engineering_forbid_delete,
    aws_bedrockagentcore_policy.marketing_list_tables,
    aws_bedrockagentcore_policy.marketing_describe_table,
  ]
}

# --- Gateway Target (Lambda) ---

resource "aws_bedrockagentcore_gateway_target" "database_tools" {
  name               = "DatabaseTools"
  description        = "Lambda function target for database tools"
  gateway_identifier = aws_bedrockagentcore_gateway.main.gateway_identifier

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.db_tools.arn
        tool_schema {
          inline_payload = jsonencode([
            {
              name        = "run_query"
              description = "Execute a read-only SQL query against the shared database"
              inputSchema = {
                type = "object"
                properties = {
                  sql      = { type = "string", description = "The SQL SELECT query to execute" }
                  database = { type = "string", description = "Target database name" }
                }
                required = ["sql", "database"]
              }
            },
            {
              name        = "list_tables"
              description = "List all tables in a database with their row counts"
              inputSchema = {
                type = "object"
                properties = {
                  database = { type = "string", description = "Target database name" }
                }
                required = ["database"]
              }
            },
            {
              name        = "delete_records"
              description = "Delete records matching a condition from a table"
              inputSchema = {
                type = "object"
                properties = {
                  table     = { type = "string", description = "Table to delete from" }
                  condition = { type = "string", description = "WHERE clause condition for deletion" }
                  database  = { type = "string", description = "Target database name" }
                }
                required = ["table", "condition", "database"]
              }
            },
            {
              name        = "describe_table"
              description = "Get schema details for a specific table"
              inputSchema = {
                type = "object"
                properties = {
                  table    = { type = "string", description = "Table name to describe" }
                  database = { type = "string", description = "Target database name" }
                }
                required = ["table", "database"]
              }
            }
          ])
        }
      }
    }
  }

  credential_provider_configurations {
    credential_provider_type = "GATEWAY_IAM_ROLE"
  }
}
