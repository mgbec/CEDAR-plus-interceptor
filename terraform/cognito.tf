# =============================================================
# Cognito User Pool — Identity Provider for the Gateway
# =============================================================
# Creates a user pool with three groups (admins, engineering, marketing)
# that map directly to the Cedar policy principals.
# =============================================================

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"

  # Password policy — relaxed for testing, tighten for production
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  # Use email as the sign-in alias
  username_attributes = ["email"]

  auto_verified_attributes = ["email"]

  # Schema: add a custom attribute for team/department if needed
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = {
    Project = var.project_name
  }
}

# --- User Pool Domain (needed for hosted UI / token endpoint) ---

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# --- App Client (used by the agent to authenticate) ---

resource "aws_cognito_user_pool_client" "agent" {
  name         = "${var.project_name}-agent-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # Generate a client secret (needed for client_credentials flow)
  generate_secret = true

  # Supported auth flows
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  # Token validity
  access_token_validity  = 1  # hours
  id_token_validity      = 1  # hours
  refresh_token_validity = 30 # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Include groups claim in the access token
  # This is what the gateway authorizer and Cedar policies use
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  callback_urls                        = ["http://localhost:3000/callback"]
  supported_identity_providers         = ["COGNITO"]

  # Prevent user existence errors from leaking info
  prevent_user_existence_errors = "ENABLED"
}

# --- Resource Server (defines custom scopes if needed later) ---

resource "aws_cognito_resource_server" "api" {
  identifier   = "data-platform-api"
  name         = "Data Platform API"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "tools.invoke"
    scope_description = "Invoke gateway tools"
  }
}

# --- Groups (map to Cedar policy principals) ---

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Full access to all database tools (100 req/hr)"
}

resource "aws_cognito_user_group" "engineering" {
  name         = "engineering"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Query and read access, no deletions (50 req/hr)"
}

resource "aws_cognito_user_group" "marketing" {
  name         = "marketing"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Table listing and schema access only (20 req/hr)"
}

# --- Test Users (one per group for easy testing) ---

resource "aws_cognito_user" "admin_user" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "admin@example.com"

  attributes = {
    email          = "admin@example.com"
    email_verified = "true"
  }

  temporary_password = var.test_user_password
}

resource "aws_cognito_user" "engineer_user" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "engineer@example.com"

  attributes = {
    email          = "engineer@example.com"
    email_verified = "true"
  }

  temporary_password = var.test_user_password
}

resource "aws_cognito_user" "marketing_user" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = "marketing@example.com"

  attributes = {
    email          = "marketing@example.com"
    email_verified = "true"
  }

  temporary_password = var.test_user_password
}

# --- Group Memberships ---

resource "aws_cognito_user_in_group" "admin_membership" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.admins.name
  username     = aws_cognito_user.admin_user.username
}

resource "aws_cognito_user_in_group" "engineer_membership" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.engineering.name
  username     = aws_cognito_user.engineer_user.username
}

resource "aws_cognito_user_in_group" "marketing_membership" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.marketing.name
  username     = aws_cognito_user.marketing_user.username
}
