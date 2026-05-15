#!/usr/bin/env bash
# =============================================================
# Create Cedar Policies via AgentCore API (using Python/boto3)
#
# The AWS CLI doesn't support bedrock-agentcore-control yet,
# but boto3 does. This script calls a Python helper.
#
# Usage:
#   ./scripts/create-policies.sh [gateway-arn]
#
# If gateway-arn is not provided, it reads from terraform output.
#
# Prerequisites:
#   - boto3 installed (pip install boto3)
#   - AWS credentials configured
#   - Terraform applied (for gateway ARN on second run)
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Get gateway ARN from terraform if not provided
GATEWAY_ARN="${1:-}"
if [[ -z "$GATEWAY_ARN" ]]; then
  GATEWAY_ARN=$(terraform -chdir="$TERRAFORM_DIR" output -raw gateway_arn 2>/dev/null || echo "")
fi

export GATEWAY_ARN
export TERRAFORM_DIR

python3 "${SCRIPT_DIR}/create_policies.py"
