#!/usr/bin/env bash
# =============================================================
# Get a JWT access token from Cognito for a test user.
#
# Usage:
#   ./scripts/get-token.sh <email> [password]
#
# Examples:
#   ./scripts/get-token.sh admin@example.com
#   ./scripts/get-token.sh engineer@example.com MyPassword1
#   ./scripts/get-token.sh marketing@example.com
#
# The script uses USER_PASSWORD_AUTH flow. On first login with a
# temporary password, it will handle the NEW_PASSWORD_REQUIRED
# challenge by setting the same password as permanent.
#
# Prerequisites:
#   - aws CLI configured with appropriate credentials
#   - jq installed
#   - terraform outputs available (run from project root)
# =============================================================

set -euo pipefail

EMAIL="${1:?Usage: $0 <email> [password]}"
PASSWORD="${2:-TestPass1}"

# Get Cognito config from terraform outputs
TERRAFORM_DIR="$(dirname "$0")/../terraform"

USER_POOL_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw cognito_user_pool_id 2>/dev/null)
CLIENT_ID=$(terraform -chdir="$TERRAFORM_DIR" output -raw cognito_app_client_id 2>/dev/null)
CLIENT_SECRET=$(terraform -chdir="$TERRAFORM_DIR" output -raw cognito_app_client_secret 2>/dev/null)
REGION=$(terraform -chdir="$TERRAFORM_DIR" output -raw 2>/dev/null || echo "us-east-1")

if [[ -z "$USER_POOL_ID" || -z "$CLIENT_ID" ]]; then
  echo "Error: Could not read terraform outputs. Run 'terraform apply' first." >&2
  exit 1
fi

# Compute SECRET_HASH (required when app client has a secret)
SECRET_HASH=$(printf '%s' "${EMAIL}${CLIENT_ID}" | openssl dgst -sha256 -hmac "$CLIENT_SECRET" -binary | base64)

echo "Authenticating ${EMAIL}..." >&2

# Initiate auth
AUTH_RESULT=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters "USERNAME=${EMAIL},PASSWORD=${PASSWORD},SECRET_HASH=${SECRET_HASH}" \
  --region "${AWS_REGION:-us-east-1}" \
  2>&1)

# Check if we got a challenge (first login with temp password)
CHALLENGE=$(echo "$AUTH_RESULT" | jq -r '.ChallengeName // empty')

if [[ "$CHALLENGE" == "NEW_PASSWORD_REQUIRED" ]]; then
  echo "Handling NEW_PASSWORD_REQUIRED challenge (setting permanent password)..." >&2
  SESSION=$(echo "$AUTH_RESULT" | jq -r '.Session')

  AUTH_RESULT=$(aws cognito-idp respond-to-auth-challenge \
    --client-id "$CLIENT_ID" \
    --challenge-name NEW_PASSWORD_REQUIRED \
    --session "$SESSION" \
    --challenge-responses "USERNAME=${EMAIL},NEW_PASSWORD=${PASSWORD},SECRET_HASH=${SECRET_HASH}" \
    --region "${AWS_REGION:-us-east-1}" \
    2>&1)
fi

# Extract tokens
ACCESS_TOKEN=$(echo "$AUTH_RESULT" | jq -r '.AuthenticationResult.AccessToken // empty')
ID_TOKEN=$(echo "$AUTH_RESULT" | jq -r '.AuthenticationResult.IdToken // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Error: Authentication failed." >&2
  echo "$AUTH_RESULT" >&2
  exit 1
fi

# Show token info
echo "" >&2
echo "=== Token Info ===" >&2
echo "User: ${EMAIL}" >&2
echo "Groups: $(echo "$ID_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."cognito:groups" // [] | join(", ")')" >&2
echo "Expires: $(echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.exp | todate')" >&2
echo "" >&2

# Output just the access token (for piping into curl)
echo "$ACCESS_TOKEN"
